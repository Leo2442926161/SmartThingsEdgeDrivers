-- Copyright 2026 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local data_types = require "st.zigbee.data_types"
local cluster_base = require "st.zigbee.cluster_base"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local capabilities = require "st.capabilities"
local battery_defaults = require "st.zigbee.defaults.battery_defaults"

local HEIMAN_MFG_CODE = 0x120B
local HEIMAN_SS_CONTROL_CLUSTER = 0xFC90

local MUTE_CONTROL_ATTR = 0x0008
local MUTE_STATUS_ATTR = 0x0009
local SIREN_CONTROL_ATTR = 0x0012
local SMOKE_CONCENTRATION_ATTR = 0x0016

local IASZone = zcl_clusters.IASZone
local TemperatureMeasurement = zcl_clusters.TemperatureMeasurement
local PowerConfiguration = zcl_clusters.PowerConfiguration

local smokeDetector = capabilities.smokeDetector
local audioMute = capabilities.audioMute
local selfCheck = capabilities["stse.selfCheck"]
local alarm_cap = capabilities.alarm

local smokeLevel = capabilities.smokeLevel

local CONFIGURATIONS = {
  {
    cluster = HEIMAN_SS_CONTROL_CLUSTER,
    attribute = MUTE_STATUS_ATTR,
    minimum_interval = 1,
    maximum_interval = 3600,
    data_type = data_types.Uint16,
    reportable_change = 1
  },
  {
    cluster = HEIMAN_SS_CONTROL_CLUSTER,
    attribute = SMOKE_CONCENTRATION_ATTR,
    minimum_interval = 1,
    maximum_interval = 3600,
    data_type = data_types.Uint8,
    reportable_change = 1
  },
  {
    cluster = TemperatureMeasurement.ID,
    attribute = TemperatureMeasurement.attributes.MeasuredValue.ID,
    minimum_interval = 60,
    maximum_interval = 600,
    data_type = TemperatureMeasurement.attributes.MeasuredValue.base_type,
    reportable_change = 100
  },
  {
    cluster = PowerConfiguration.ID,
    attribute = PowerConfiguration.attributes.BatteryVoltage.ID,
    minimum_interval = 30,
    maximum_interval = 3600,
    data_type = PowerConfiguration.attributes.BatteryVoltage.base_type,
    reportable_change = 1
  }
}

local function handle_zone_status(driver, device, zone_status, zb_rx)
  if zone_status:is_alarm1_set() then
    device:emit_event(smokeDetector.smoke.detected())
  elseif zone_status:is_test_set() then
    device:emit_event(smokeDetector.smoke.tested())
  else
    device:emit_event(smokeDetector.smoke.clear())
    local was_testing = device:get_field("self_test_active")
    if was_testing then
      device:set_field("self_test_active", false, { persist = true })
      device:emit_event(selfCheck.selfCheckState.selfCheckCompleted())
      device.thread:call_with_delay(1, function()
        device:emit_event(selfCheck.selfCheckState.idle())
      end)
    end
  end
  if zone_status:is_test_set() then
    device:emit_event(selfCheck.selfCheckState.selfChecking())
  end
end

local function ias_zone_status_attr_handler(driver, device, zone_status, zb_rx)
  handle_zone_status(driver, device, zone_status, zb_rx)
end

local function ias_zone_status_change_handler(driver, device, zb_rx)
  local zone_status = zb_rx.body.zcl_body.zone_status
  handle_zone_status(driver, device, zone_status, zb_rx)
end

local function mute_status_handler(driver, device, value, zb_rx)
  if value.value == 0 then
    device:emit_event(audioMute.mute.unmuted())
  else
    device:emit_event(audioMute.mute.muted())
  end
end

local function smoke_concentration_handler(driver, device, value, zb_rx)
  local level = value.value / 100
  device:emit_event(smokeLevel.smokeLevel(level))
end

local function mute_handler(driver, device, command)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, MUTE_CONTROL_ATTR, HEIMAN_MFG_CODE, data_types.Uint8, 1))
end

local function unmute_handler(driver, device, command)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, MUTE_CONTROL_ATTR, HEIMAN_MFG_CODE, data_types.Uint8, 0))
end

local function start_self_check_handler(driver, device, command)
  device:emit_event(selfCheck.selfCheckState.selfChecking())
  device:set_field("self_test_active", true, { persist = true })
  local cmd = nil
  local ok = false
  if IASZone.server and IASZone.server.commands and IASZone.server.commands.InitiateTestMode then
    ok, cmd = pcall(function()
      return IASZone.server.commands.InitiateTestMode(device, data_types.Uint8(5), data_types.Uint8(0))
    end)
  end
  if ok and cmd then
    device:send(cmd)
  end
end

local function alarm_siren_handler(driver, device, command)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, SIREN_CONTROL_ATTR, HEIMAN_MFG_CODE, data_types.Enum8, 1))
end

local function alarm_off_handler(driver, device, command)
  device:send(cluster_base.write_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, SIREN_CONTROL_ATTR, HEIMAN_MFG_CODE, data_types.Enum8, 0))
end

local function device_init(driver, device)
  battery_defaults.build_linear_voltage_init(2.3, 3.0)(driver, device)
  if CONFIGURATIONS ~= nil then
    for _, attribute in ipairs(CONFIGURATIONS) do
      device:add_configured_attribute(attribute)
    end
  end
end

local function device_added(driver, device)
  device:emit_event(smokeDetector.smoke.clear())
  device:emit_event(audioMute.mute.unmuted())
  device:emit_event(selfCheck.selfCheckState.idle())
  device:emit_event(alarm_cap.alarm.off())
  device:emit_event(smokeLevel.smokeLevel(0))
end

local function do_configure(driver, device)
  device:configure()
end

local function do_refresh(driver, device, command)
  device:send(cluster_base.read_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, MUTE_STATUS_ATTR, HEIMAN_MFG_CODE))
  device:send(cluster_base.read_manufacturer_specific_attribute(device,
    HEIMAN_SS_CONTROL_CLUSTER, SMOKE_CONCENTRATION_ATTR, HEIMAN_MFG_CODE))
  device:send(IASZone.attributes.ZoneStatus:read(device))
end

local heiman_hs1sa_smoke_sensor = {
  NAME = "HEIMAN HS1SA-E-PLUS",
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    doConfigure = do_configure,
  },
  capability_handlers = {
    [audioMute.ID] = {
      [audioMute.commands.mute.NAME] = mute_handler,
      [audioMute.commands.unmute.NAME] = unmute_handler,
    },
    [selfCheck.ID] = {
      ["startSelfCheck"] = start_self_check_handler,
    },
    [alarm_cap.ID] = {
      [alarm_cap.commands.siren.NAME] = alarm_siren_handler,
      [alarm_cap.commands.off.NAME] = alarm_off_handler,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
  },
  zigbee_handlers = {
    attr = {
      [HEIMAN_SS_CONTROL_CLUSTER] = {
        [MUTE_STATUS_ATTR] = mute_status_handler,
        [SMOKE_CONCENTRATION_ATTR] = smoke_concentration_handler,
      },
      [IASZone.ID] = {
        [IASZone.attributes.ZoneStatus.ID] = ias_zone_status_attr_handler,
      },
    },
    cluster = {
      [IASZone.ID] = {
        [IASZone.client.commands.ZoneStatusChangeNotification.ID] = ias_zone_status_change_handler,
      },
    },
  },
  can_handle = require("heiman-hs1sa-e-plus.can_handle"),
}

return heiman_hs1sa_smoke_sensor
