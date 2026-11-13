-- main.lua
-- Boox Refresh Manager: Pure in-app refresh coalescing and waveform clamping
-- Eliminates full-screen white flashes when navigating menus and Bookshelf in Regal mode on Onyx Boox devices.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

-- Determine plugin path for relative requires
local plugin_name = (...)
local plugin_dir = ""
if type(plugin_name) == "string" then
    plugin_dir = plugin_name:match("(.-)[^/%.]+$") or ""
end

local WaveformClamper = require(plugin_dir .. "lib/waveform_clamper")
local RefreshCoalescer = require(plugin_dir .. "lib/refresh_coalescer")

local BooxRefreshManager = WidgetContainer:extend{
    name = "boox_refresh_manager",
    is_doc_only = false,
}

local orig_setDirty = nil

function BooxRefreshManager:init()
    BooxRefreshManager.instance = self

    -- Read saved settings if present
    local enabled = true
    if G_reader_settings and G_reader_settings.readSetting then
        local setting_val = G_reader_settings:readSetting("boox_refresh_manager_enabled")
        if setting_val ~= nil then
            enabled = (setting_val == true)
        end
    end

    WaveformClamper.enabled = enabled
    WaveformClamper.init(UIManager, logger)

    RefreshCoalescer.enabled = enabled
    RefreshCoalescer.init(WaveformClamper, UIManager, Screen, logger)

    -- Hook UIManager:setDirty to clamp flashing waveforms in UI contexts
    if not orig_setDirty and UIManager and UIManager.setDirty then
        orig_setDirty = UIManager.setDirty
        UIManager.setDirty = function(self_ui, widget, mode, ...)
            if WaveformClamper.enabled then
                mode = WaveformClamper.clampMode(widget, mode)
            end
            return orig_setDirty(self_ui, widget, mode, ...)
        end
    end

    -- Install Screen hooks for refresh coalescing and multi-slice suppression
    RefreshCoalescer.installHooks()

    -- Apply optimal settings automatically on init
    self:applyOptimalSettings()

    logger.info(string.format("[BooxRefreshManager] Initialized (enabled: %s, coalesce window: %dms)",
        tostring(enabled), math.floor(RefreshCoalescer.coalesce_window_s * 1000)))
end

function BooxRefreshManager:applyOptimalSettings()
    -- 1. Ensure KOReader avoid_flashing_ui setting is enabled
    if G_reader_settings and G_reader_settings.saveSetting then
        G_reader_settings:saveSetting("avoid_flashing_ui", true)
        G_reader_settings:saveSetting("boox_refresh_manager_enabled", true)
        pcall(function() G_reader_settings:flush() end)
    end

    WaveformClamper.enabled = true
    RefreshCoalescer.enabled = true
end

function BooxRefreshManager:onSuspend()
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onPause()
    RefreshCoalescer.flush()
    RefreshCoalescer.cancel()
end

function BooxRefreshManager:onResume()
    -- Ensure optimal settings are active on resume
    if WaveformClamper.enabled then
        if G_reader_settings and G_reader_settings.saveSetting then
            G_reader_settings:saveSetting("avoid_flashing_ui", true)
        end
    end
end

function BooxRefreshManager:onDestroy()
    RefreshCoalescer.removeHooks()
    if orig_setDirty and UIManager then
        UIManager.setDirty = orig_setDirty
        orig_setDirty = nil
    end
end

function BooxRefreshManager:addToMainMenu(menu_items)
    menu_items.boox_refresh_manager = {
        text = _("Boox Refresh Manager"),
        sorting_hint = "device",
        keep_menu_open = true,
        sub_item_table_func = function()
            return {
                {
                    text = _("Regal Mode Flash Suppression"),
                    help_text = _("Suppresses full-screen white flashes when navigating menus and Bookshelf in Regal mode, while preserving full color fidelity and crisp Regal page turns."),
                    checked_func = function()
                        return WaveformClamper.enabled
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local new_val = not WaveformClamper.enabled
                        WaveformClamper.enabled = new_val
                        RefreshCoalescer.enabled = new_val
                        if G_reader_settings and G_reader_settings.saveSetting then
                            G_reader_settings:saveSetting("boox_refresh_manager_enabled", new_val)
                            pcall(function() G_reader_settings:flush() end)
                        end
                        if new_val then
                            BooxRefreshManager.instance:applyOptimalSettings()
                        end
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = _("Restore Optimal Boox Settings"),
                    help_text = _("Restores all optimal settings with a single tap: enables Regal Flash Suppression, enables Avoid Flashing UI in KOReader settings, and verifies refresh coalescing."),
                    keep_menu_open = false,
                    callback = function()
                        BooxRefreshManager.instance:applyOptimalSettings()
                        UIManager:show(InfoMessage:new{
                            text = _("Optimal Boox settings restored:\n• Regal Flash Suppression: Enabled\n• Avoid Flashing UI: Enabled\n• Refresh Coalescing: 35ms Active\n\nEnsure Boox E-ink Center is set to:\n• Refresh Mode: Regal\n• Full Color / Regal Fidelity"),
                            timeout = 8,
                        })
                    end,
                },
                {
                    text = _("Settings & Status Diagnostics"),
                    help_text = _("Displays current state of flash suppression, coalesce window, and KOReader avoid_flashing_ui setting."),
                    keep_menu_open = false,
                    callback = function()
                        local avoid_flash = false
                        if G_reader_settings and G_reader_settings.isTrue then
                            avoid_flash = G_reader_settings:isTrue("avoid_flashing_ui")
                        end
                        local status_text = string.format(
                            "Device: NoteAir5C (Color E-Ink)\nRegal Flash Suppression: %s\nAvoid Flashing UI: %s\nCoalesce Window: %dms\nReader Page Turns: Native Regal (Unclamped)",
                            WaveformClamper.enabled and "ACTIVE" or "DISABLED",
                            avoid_flash and "ENABLED" or "DISABLED",
                            math.floor(RefreshCoalescer.coalesce_window_s * 1000)
                        )
                        UIManager:show(InfoMessage:new{
                            text = status_text,
                            timeout = 8,
                        })
                    end,
                },
            }
        end,
    }
end

return BooxRefreshManager
