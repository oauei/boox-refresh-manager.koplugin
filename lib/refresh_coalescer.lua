-- refresh_coalescer.lua
-- Coalesces rapid successive UI redraws and slice animations into a single atomic
-- partial refresh within a 35ms window to prevent tripping the Onyx Qualcomm/SDM
-- display compositor into emergency full-screen waveform 16 flashes.

local WaveformClamper = nil
local UIManager = nil
local Screen = nil
local logger = nil

local RefreshCoalescer = {
    enabled = true,
    coalesce_window_s = 0.035, -- 35ms static window
    merged_rect = nil,
    flush_callback = nil,
    orig_refreshUI = nil,
    orig_refreshFast = nil,
    orig_refreshFull = nil,
    orig_refreshFlashUI = nil,
    orig_refreshFlashPartial = nil,
    orig_yieldToEPDC = nil,
    hooked = false,
}

function RefreshCoalescer.init(clamper, ui_mgr, screen_mgr, log_mgr)
    WaveformClamper = clamper or require("lib/waveform_clamper")
    UIManager = ui_mgr or require("ui/uimanager")
    Screen = screen_mgr or require("device").screen
    logger = log_mgr or require("logger")
end

local _reusable_rect = { x = 0, y = 0, w = 0, h = 0, d = nil }

local function _static_flush_cb()
    RefreshCoalescer.flush()
end

function RefreshCoalescer.queueRefresh(x, y, w, h, d)
    if not Screen then return end

    if not x or not y or not w or not h then
        local sw = Screen.getWidth and Screen:getWidth() or 2480
        local sh = Screen.getHeight and Screen:getHeight() or 1860
        x, y, w, h = 0, 0, sw, sh
    end

    if not RefreshCoalescer.merged_rect then
        _reusable_rect.x = x
        _reusable_rect.y = y
        _reusable_rect.w = w
        _reusable_rect.h = h
        _reusable_rect.d = d
        RefreshCoalescer.merged_rect = _reusable_rect
    else
        local mr = RefreshCoalescer.merged_rect
        local min_x = math.min(mr.x, x)
        local min_y = math.min(mr.y, y)
        local max_x = math.max(mr.x + mr.w, x + w)
        local max_y = math.max(mr.y + mr.h, y + h)
        mr.x = min_x
        mr.y = min_y
        mr.w = max_x - min_x
        mr.h = max_y - min_y
        mr.d = d or mr.d
    end

    if not RefreshCoalescer.flush_callback and UIManager and UIManager.scheduleIn then
        RefreshCoalescer.flush_callback = _static_flush_cb
        UIManager:scheduleIn(RefreshCoalescer.coalesce_window_s, RefreshCoalescer.flush_callback)
    end
end

function RefreshCoalescer.flush()
    if RefreshCoalescer.flush_callback and UIManager and UIManager.unschedule then
        pcall(function() UIManager:unschedule(RefreshCoalescer.flush_callback) end)
        RefreshCoalescer.flush_callback = nil
    else
        RefreshCoalescer.flush_callback = nil
    end

    local rect = RefreshCoalescer.merged_rect
    RefreshCoalescer.merged_rect = nil

    if rect and Screen and RefreshCoalescer.orig_refreshUI then
        if logger and logger.dbg then
            logger.dbg(string.format("[RefreshCoalescer] Flushing coalesced UI refresh: %d,%d %dx%d",
                rect.x, rect.y, rect.w, rect.h))
        end
        RefreshCoalescer.orig_refreshUI(Screen, rect.x, rect.y, rect.w, rect.h, rect.d)
    end
end

function RefreshCoalescer.cancel()
    if RefreshCoalescer.flush_callback and UIManager and UIManager.unschedule then
        pcall(function() UIManager:unschedule(RefreshCoalescer.flush_callback) end)
    end
    RefreshCoalescer.flush_callback = nil
    RefreshCoalescer.merged_rect = nil
end

function RefreshCoalescer.installHooks()
    if RefreshCoalescer.hooked or not Screen then return end

    RefreshCoalescer.orig_refreshUI = Screen.refreshUI
    RefreshCoalescer.orig_refreshPartial = Screen.refreshPartial
    RefreshCoalescer.orig_refreshFast = Screen.refreshFast
    RefreshCoalescer.orig_refreshFull = Screen.refreshFull
    RefreshCoalescer.orig_refreshFlashUI = Screen.refreshFlashUI
    RefreshCoalescer.orig_refreshFlashPartial = Screen.refreshFlashPartial
    RefreshCoalescer.orig_yieldToEPDC = Screen.yieldToEPDC

    -- Hook Screen:refreshUI
    Screen.refreshUI = function(self_scr, x, y, w, h, d)
        if not RefreshCoalescer.enabled then
            if RefreshCoalescer.orig_refreshUI then
                return RefreshCoalescer.orig_refreshUI(self_scr, x, y, w, h, d)
            end
            return
        end

        -- If document reader view without dialogs, flush pending UI rect and pass through
        if WaveformClamper and WaveformClamper.isReaderDocumentView() then
            if RefreshCoalescer.merged_rect then
                RefreshCoalescer.flush()
            end
            if RefreshCoalescer.orig_refreshUI then
                return RefreshCoalescer.orig_refreshUI(self_scr, x, y, w, h, d)
            end
            return
        end

        -- In UI context, coalesce rapid successive partial redraws
        RefreshCoalescer.queueRefresh(x, y, w, h, d)
    end

    -- Hook Screen:refreshPartial (divert to refreshUI during continuous scroll pan)
    if Screen.refreshPartial then
        Screen.refreshPartial = function(self_scr, x, y, w, h, d)
            if RefreshCoalescer.enabled
                and WaveformClamper
                and WaveformClamper.scroll_pan_active
                and WaveformClamper.isReaderDocumentView()
            then
                return Screen.refreshUI(self_scr, x, y, w, h, d)
            end
            if RefreshCoalescer.orig_refreshPartial then
                return RefreshCoalescer.orig_refreshPartial(self_scr, x, y, w, h, d)
            end
        end
    end

    -- Hook Screen:refreshFull
    Screen.refreshFull = function(self_scr, x, y, w, h, d)
        if not RefreshCoalescer.enabled then
            if RefreshCoalescer.orig_refreshFull then
                return RefreshCoalescer.orig_refreshFull(self_scr, x, y, w, h, d)
            end
            return
        end

        -- Document page turns in ReaderUI are allowed to perform native full refreshes,
        -- unless we are actively drag-scrolling in continuous scroll mode.
        if WaveformClamper and WaveformClamper.isReaderDocumentView() then
            if WaveformClamper.scroll_pan_active then
                return Screen.refreshUI(self_scr, x, y, w, h, d)
            end
            if RefreshCoalescer.merged_rect then
                RefreshCoalescer.flush()
            end
            if RefreshCoalescer.orig_refreshFull then
                return RefreshCoalescer.orig_refreshFull(self_scr, x, y, w, h, d)
            end
            return
        end

        -- In UI context, clamp full refreshes to non-flashing coalesced UI refreshes
        if logger and logger.dbg then
            logger.dbg("[RefreshCoalescer] Diverting Screen:refreshFull -> coalesced refreshUI in UI context")
        end
        RefreshCoalescer.queueRefresh(x, y, w, h, d)
    end

    -- Hook Screen:refreshFlashUI
    if Screen.refreshFlashUI then
        Screen.refreshFlashUI = function(self_scr, x, y, w, h, d)
            if not RefreshCoalescer.enabled then
                if RefreshCoalescer.orig_refreshFlashUI then
                    return RefreshCoalescer.orig_refreshFlashUI(self_scr, x, y, w, h, d)
                end
                return
            end

            -- Always clamp flash UI to non-flashing UI
            Screen.refreshUI(self_scr, x, y, w, h, d)
        end
    end

    -- Hook Screen:refreshFlashPartial
    if Screen.refreshFlashPartial then
        Screen.refreshFlashPartial = function(self_scr, x, y, w, h, d)
            if not RefreshCoalescer.enabled then
                if RefreshCoalescer.orig_refreshFlashPartial then
                    return RefreshCoalescer.orig_refreshFlashPartial(self_scr, x, y, w, h, d)
                end
                return
            end

            if Screen.refreshPartial then
                return Screen:refreshPartial(x, y, w, h, d)
            else
                return Screen.refreshUI(self_scr, x, y, w, h, d)
            end
        end
    end

    -- Hook Screen:refreshFast
    if Screen.refreshFast then
        Screen.refreshFast = function(self_scr, x, y, w, h, d)
            if RefreshCoalescer.enabled and WaveformClamper and WaveformClamper.scroll_pan_active then
                return Screen.refreshUI(self_scr, x, y, w, h, d)
            end
            if RefreshCoalescer.orig_refreshFast then
                return RefreshCoalescer.orig_refreshFast(self_scr, x, y, w, h, d)
            end
        end
    end

    -- Hook Screen:yieldToEPDC
    Screen.yieldToEPDC = function(self_scr, us)
        if not RefreshCoalescer.enabled then
            if RefreshCoalescer.orig_yieldToEPDC then
                return RefreshCoalescer.orig_yieldToEPDC(self_scr, us)
            end
            return
        end

        -- Suppress EPDC stalls and hardware flasher triggers during multi-slice UI animations or active scroll pan
        if not (WaveformClamper and WaveformClamper.isReaderDocumentView()) or (WaveformClamper and WaveformClamper.scroll_pan_active) then
            return
        end

        if RefreshCoalescer.orig_yieldToEPDC then
            return RefreshCoalescer.orig_yieldToEPDC(self_scr, us)
        end
    end

    RefreshCoalescer.hooked = true
    if logger and logger.info then
        logger.info("[RefreshCoalescer] Screen refresh hooks installed")
    end
end

function RefreshCoalescer.removeHooks()
    if not RefreshCoalescer.hooked or not Screen then return end

    RefreshCoalescer.flush()

    if RefreshCoalescer.orig_refreshUI then
        Screen.refreshUI = RefreshCoalescer.orig_refreshUI
        RefreshCoalescer.orig_refreshUI = nil
    end
    if RefreshCoalescer.orig_refreshPartial then
        Screen.refreshPartial = RefreshCoalescer.orig_refreshPartial
        RefreshCoalescer.orig_refreshPartial = nil
    end
    if RefreshCoalescer.orig_refreshFast then
        Screen.refreshFast = RefreshCoalescer.orig_refreshFast
        RefreshCoalescer.orig_refreshFast = nil
    end
    if RefreshCoalescer.orig_refreshFull then
        Screen.refreshFull = RefreshCoalescer.orig_refreshFull
        RefreshCoalescer.orig_refreshFull = nil
    end
    if RefreshCoalescer.orig_refreshFlashUI then
        Screen.refreshFlashUI = RefreshCoalescer.orig_refreshFlashUI
        RefreshCoalescer.orig_refreshFlashUI = nil
    end
    if RefreshCoalescer.orig_refreshFlashPartial then
        Screen.refreshFlashPartial = RefreshCoalescer.orig_refreshFlashPartial
        RefreshCoalescer.orig_refreshFlashPartial = nil
    end
    if RefreshCoalescer.orig_yieldToEPDC then
        Screen.yieldToEPDC = RefreshCoalescer.orig_yieldToEPDC
        RefreshCoalescer.orig_yieldToEPDC = nil
    end

    RefreshCoalescer.hooked = false
    if logger and logger.info then
        logger.info("[RefreshCoalescer] Screen refresh hooks removed")
    end
end

return RefreshCoalescer
