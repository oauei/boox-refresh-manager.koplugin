-- waveform_clamper.lua
-- Clamps flashing refresh waveforms (flashui, flashpartial, full) in UI contexts
-- while preserving native Regal page turn waveforms in ReaderUI.

local WaveformClamper = {
    enabled = true,
    scroll_pan_active = false,
    scroll_epd_mode = 2,
}

local UIManager = nil
local logger = nil

function WaveformClamper.init(ui_mgr, log_mgr)
    UIManager = ui_mgr or require("ui/uimanager")
    logger = log_mgr or require("logger")
end

-- Inspects window stack to determine if the user is actively viewing a document in ReaderUI
-- without any open menus, dialogs, or popups on top.
function WaveformClamper.isReaderDocumentView()
    if not UIManager then return false end

    local stack = UIManager._window_stack
    if not stack or #stack == 0 then
        return false
    end

    local top_widget = nil
    for i = #stack, 1, -1 do
        local entry = stack[i]
        local w = (type(entry) == "table" and entry.widget) or entry
        if w and not w.invisible and not w.toast then
            top_widget = w
            break
        end
    end
    if not top_widget then
        return false
    end

    -- Check if top widget is ReaderUI
    local is_reader = false
    if top_widget.name == "ReaderUI" then
        is_reader = true
    elseif top_widget.document and top_widget.view and top_widget.ui then
        is_reader = true
    elseif top_widget.is_reader_ui then
        is_reader = true
    end

    if not is_reader then
        return false
    end

    -- If ReaderUI is the root, verify there is no active modal/dialog widget
    if UIManager.hasActiveWidget and UIManager:hasActiveWidget() then
        -- An active modal dialog is displayed over ReaderUI
        return false
    end

    return true
end

-- Clamps refresh mode requested by UIManager:setDirty or widgets
function WaveformClamper.clampMode(widget, mode)
    if not WaveformClamper.enabled then
        return mode
    end

    if not mode then
        return "ui"
    end

    -- In document reader mode without dialogs, clamp to smooth "ui" mode while actively
    -- drag-scrolling in continuous scroll mode, otherwise preserve native reader waveforms.
    if WaveformClamper.scroll_pan_active then
        if mode == "fast" or mode == "partial" or mode == "flashpartial" or mode == "full" or mode == "flashui" then
            return "ui"
        end
        return mode
    end

    if WaveformClamper.isReaderDocumentView() then
        return mode
    end

    -- In UI mode (Bookshelf, FileManager, TouchMenu, Dialogs, etc.):
    -- Downgrade any flashing waveforms to clean partial waveforms
    if mode == "flashui" then
        if logger and logger.dbg then
            logger.dbg("[WaveformClamper] Clamping flashui -> ui in UI context")
        end
        return "ui"
    elseif mode == "flashpartial" then
        if logger and logger.dbg then
            logger.dbg("[WaveformClamper] Clamping flashpartial -> partial in UI context")
        end
        return "partial"
    elseif mode == "full" then
        if logger and logger.dbg then
            logger.dbg("[WaveformClamper] Clamping full -> ui in UI context")
        end
        return "ui"
    end

    return mode
end

return WaveformClamper
