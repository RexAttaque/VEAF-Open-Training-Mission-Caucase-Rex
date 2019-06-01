-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- VEAF carrier command and functions for DCS World
-- By zip (2018)
--
-- Features:
-- ---------
-- * Radio menus allow starting and ending carrier operations. Carriers go back to their initial point when operations are ended
-- * Works with all current and future maps (Caucasus, NTTR, Normandy, PG, ...)
--
-- Prerequisite:
-- ------------
-- * This script requires DCS 2.5.1 or higher and MIST 4.3.74 or higher.
-- * It also requires the base veaf.lua script library (version 1.0 or higher)
--
-- Load the script:
-- ----------------
-- 1.) Download the script and save it anywhere on your hard drive.
-- 2.) Open your mission in the mission editor.
-- 3.) Add a new trigger:
--     * TYPE   "4 MISSION START"
--     * ACTION "DO SCRIPT FILE"
--     * OPEN --> Browse to the location of MIST and click OK.
--     * ACTION "DO SCRIPT FILE"
--     * OPEN --> Browse to the location of veaf.lua and click OK.
--     * ACTION "DO SCRIPT FILE"
--     * OPEN --> Browse to the location of this script and click OK.
--     * ACTION "DO SCRIPT"
--     * set the script command to "veafCarrierOperations.initialize()" and click OK.
-- 4.) Save the mission and start it.
-- 5.) Have fun :)
--
-- Basic Usage:
-- ------------
-- Use the F10 radio menu to start and end carrier operations for every detected carrier group (having a group name like "CSG-*")
--
-------------------------------------------------------------------------------------------------------------------------------------------------------------

veafCarrierOperations = {}

-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Global settings. Stores the script constants
-------------------------------------------------------------------------------------------------------------------------------------------------------------

--- Identifier. All output in DCS.log will start with this.
veafCarrierOperations.Id = "CARRIER - "

--- Version.
veafCarrierOperations.Version = "1.3.0"

--- All the carrier groups must comply with this name
veafCarrierOperations.CarrierGroupNamePattern = "^CSG-.*$"

veafCarrierOperations.RadioMenuName = "CARRIER OPS (" .. veafCarrierOperations.Version .. ")"

veafCarrierOperations.AllCarriers = 
{
    ["LHA_Tarawa"] = 0,
    ["Stennis"] = 8, 
    ["KUZNECOW"] = 0
}

veafCarrierOperations.ALT_FOR_MEASURING_WIND = 30 -- wind is measured at 30 meters, 10 meters above deck
veafCarrierOperations.ALIGNMENT_MANOEUVER_SPEED = 8 -- carrier speed when not yet aligned to the wind (in m/s)
veafCarrierOperations.MAX_OPERATIONS_DURATION = 30 -- operations are stopped after 30 minutes
veafCarrierOperations.SCHEDULER_INTERVAL = 2 -- scheduler runs every 2 minutes -- TODO reset

-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Do not change anything below unless you know what you are doing!
-------------------------------------------------------------------------------------------------------------------------------------------------------------

--- Radio menus paths
veafCarrierOperations.rootPath = nil

--- Carrier groups data, for Carrier Operations commands
veafCarrierOperations.carriers = {}

-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Utility methods
-------------------------------------------------------------------------------------------------------------------------------------------------------------
debugMarkersErasedAtEachStep = {}
debugMarkersForTanker = {}

function veafCarrierOperations.logInfo(message)
    veaf.logInfo(veafCarrierOperations.Id .. message)
end

function veafCarrierOperations.logDebug(message)
    veaf.logDebug(veafCarrierOperations.Id .. message)
end

function veafCarrierOperations.logTrace(message)
    veaf.logTrace(veafCarrierOperations.Id .. message)
end

function veafCarrierOperations.logMarker(id, message, position, markersTable)
    if veaf.Trace then
        trigger.action.markToAll(id, "CARRIER-TRACE-"..id.." "..message, position, false) 
        table.insert(markersTable, id)
    end
    return id + 1
end

function veafCarrierOperations.cleanupLogMarkers(markersTable)
    for _, markerId in pairs(markersTable) do
        trigger.action.removeMark(markerId)    
    end
end
-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Carrier operations commands
-------------------------------------------------------------------------------------------------------------------------------------------------------------

--- Start carrier operations ; changes the radio menu item to END and make the carrier move
function veafCarrierOperations.startCarrierOperations(parameters)
    local groupName, duration = unpack(parameters)
    veafCarrierOperations.logDebug("startCarrierOperations(".. groupName .. ")")

    local carrier = veafCarrierOperations.carriers[groupName]

    if not(carrier) then
        local text = "Cannot find the carrier group "..groupName
        veafCarrierOperations.logError(text)
        trigger.action.outText(text, 5)
        return
    end

    -- find the actual carrier unit
    local group = Group.getByName(groupName)
    for _, unit in pairs(group:getUnits()) do
        local unitType = unit:getDesc()["typeName"]
        for knownCarrierType, knownCarrierDeckAngle in pairs(veafCarrierOperations.AllCarriers) do
            if unitType == knownCarrierType then
                carrier.carrierUnitName = unit:getName()
                carrier.pedroGroupName = carrier.carrierUnitName .. " Pedro" -- rescue helo unit name
                carrier.tankerGroupName = carrier.carrierUnitName .. " S3B-Tanker" -- emergency tanker unit name
                carrier.tankerRouteSet = 0
                carrier.deckAngle = knownCarrierDeckAngle
                break
            end
        end
    end
    
    veafCarrierOperations.continueCarrierOperations(groupName) -- will update the *carrier* structure

    local text = 
        "The carrier group "..groupName.." BRC will be " .. carrier.heading .. " (true) at " .. carrier.speed .. " kn \n" ..
        "Getting a good alignment may require up to 5 minutes\n"

    veafCarrierOperations.logInfo(text)
    trigger.action.outText(text, 25)

    carrier.conductingAirOperations = true
    carrier.airOperationsStartedAt = timer.getTime()
    carrier.airOperationsEndAt = carrier.airOperationsStartedAt + duration * 60

    -- change the menu
    veafCarrierOperations.logTrace("change the menu")
    veafCarrierOperations.rebuildRadioMenu()

end

--- Continue carrier operations ; make the carrier move according to the wind. Called by startCarrierOperations and by the scheduler.
function veafCarrierOperations.continueCarrierOperations(groupName)
    if not traceMarkerId then
        traceMarkerId = 2727
    end

    veafCarrierOperations.logDebug("continueCarrierOperations(".. groupName .. ")")

    local carrier = veafCarrierOperations.carriers[groupName]

    if not(carrier) then
        local text = "Cannot find the carrier group "..groupName
        veafCarrierOperations.logError(text)
        trigger.action.outText(text, 5)
        return
    end

    -- find the actual carrier unit
    local group = Group.getByName(groupName)
    local carrierUnit = Unit.getByName(carrier.carrierUnitName)
    
    -- take note of the starting position
    local startPosition = veaf.getAvgGroupPos(groupName)
    local currentHeading = 0
    if carrierUnit then 
        startPosition = carrierUnit:getPosition().p
        veafCarrierOperations.logTrace("startPosition (raw) ="..veaf.vecToString(startPosition))
        currentHeading = mist.utils.round(mist.utils.toDegree(mist.getHeading(carrierUnit)), 0)
    end    
    startPosition = { x=startPosition.x, z=startPosition.z, y=startPosition.y + veafCarrierOperations.ALT_FOR_MEASURING_WIND} -- on deck, 50 meters above the water
    veafCarrierOperations.logTrace("startPosition="..veaf.vecToString(startPosition))
    veafCarrierOperations.cleanupLogMarkers(debugMarkersErasedAtEachStep)
    traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "startPosition", startPosition, debugMarkersErasedAtEachStep)
    local carrierDistanceFromInitialPosition = ((startPosition.x - carrier.initialPosition.x)^2 + (startPosition.z - carrier.initialPosition.z)^2)^0.5
    veafCarrierOperations.logTrace("carrierDistanceFromInitialPosition="..carrierDistanceFromInitialPosition)

    -- compute magnetic deviation at carrier position
    local magdev = veaf.round(mist.getNorthCorrection(startPosition) * 180 / math.pi,1)
    veafCarrierOperations.logTrace("magdev = " .. magdev)


    -- make the carrier move
    if startPosition ~= nil then
	
        --get wind info
        local wind = atmosphere.getWind(startPosition)
        local windspeed = mist.vec.mag(wind)
        veafCarrierOperations.logTrace("windspeed="..windspeed.." m/s")

        --get wind direction sorted
        local dir = veaf.round(math.atan2(wind.z, wind.x) * 180 / math.pi,0)
        if dir < 0 then
            dir = dir + 360 --converts to positive numbers		
        end
        if dir <= 180 then
            dir = dir + 180
        else
            dir = dir - 180
        end

        dir = dir + carrier.deckAngle --to account for angle of landing deck and movement of the ship
        
        if dir > 360 then
            dir = dir - 360
        end

        veafCarrierOperations.logTrace("dir="..dir .. " (true)")

        local speed = 1
        if windspeed < 11.8611 then
            speed = 11.8611 - windspeed -- minimum 1 m/s
        end
        veafCarrierOperations.logTrace("BRC speed="..speed.." m/s")

        -- compute a new waypoint
        local headingRad = mist.utils.toRadian(dir)
        local length = 4000
        local newWaypoint = {
            x = startPosition.x + length * math.cos(headingRad),
            z = startPosition.z + length * math.sin(headingRad),
            y = startPosition.y
        }
        veafCarrierOperations.logTrace("headingRad="..headingRad)
        veafCarrierOperations.logTrace("length="..length)
        veafCarrierOperations.logTrace("newWaypoint="..veaf.vecToString(newWaypoint))
        traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "newWaypoint", newWaypoint, debugMarkersErasedAtEachStep)
        
        local actualSpeed = speed
        if math.abs(dir - currentHeading) > 15 then -- still aligning
            actualSpeed = veafCarrierOperations.ALIGNMENT_MANOEUVER_SPEED
        end
        veaf.moveGroupTo(groupName, newWaypoint, actualSpeed, 0)
        carrier.heading = dir
        carrier.speed = veaf.round(speed * 1.94384, 0)
        veafCarrierOperations.logTrace("carrier.heading = " .. carrier.heading .. " (true)")
        veafCarrierOperations.logTrace("carrier.heading = " .. carrier.heading + magdev .. " (mag)")
        veafCarrierOperations.logTrace("carrier.speed = " .. carrier.speed .. " kn")

        -- check if a Pedro group exists for this carrier
        if not(mist.getGroupData(carrier.pedroGroupName)) then
            veafCarrierOperations.logInfo("No Pedro group named " .. carrier.pedroGroupName)
        else
        -- prepare or correct the Pedro route (SH-60B, 250ft high, 1nm to the starboard side of the carrier, riding along at the same speed and heading)
            local pedroUnit = Unit.getByName(carrier.pedroGroupName)
            if (pedroUnit) then
                veafCarrierOperations.logDebug("found Pedro unit")
                -- check if unit is still alive
                if pedroUnit:getLife() < 1 then
                    pedroUnit = nil -- respawn when damaged
                end
            end
            
            -- spawn if needed
            if not(pedroUnit and carrier.pedroIsSpawned) then
                veafCarrierOperations.logDebug("respawning Pedro unit")
                mist.respawnGroup(carrier.pedroGroupName, true)
                carrier.pedroIsSpawned = true
            end

            pedroUnit = Unit.getByName(carrier.pedroGroupName)
            local pedroGroup = Group.getByName(carrier.pedroGroupName) -- group has the same name as the unit
            if (pedroGroup) then
                veafCarrierOperations.logDebug("found Pedro group")
                
                -- waypoint #1 is 250m to port
                local offsetPointOnLand, offsetPoint = veaf.computeCoordinatesOffsetFromRoute(startPosition, newWaypoint, 0, 250)
                local pedroWaypoint1 = offsetPoint
                local distanceFromWP1 = ((pedroUnit:getPosition().p.x - pedroWaypoint1.x)^2 + (pedroUnit:getPosition().p.z - pedroWaypoint1.z)^2)^0.5
                if distanceFromWP1 > 500 then
                    veafCarrierOperations.logTrace("Pedro WP1 = " .. veaf.vecToString(pedroWaypoint1))
                    traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "pedroWaypoint1", pedroWaypoint1, debugMarkersErasedAtEachStep)
                else
                    pedroWaypoint1 = nil
                end

                -- waypoint #2 is 250m to port, near the end of the carrier route
                local offsetPointOnLand, offsetPoint = veaf.computeCoordinatesOffsetFromRoute(startPosition, newWaypoint, length - 250, 250)
                local pedroWaypoint2 = offsetPoint
                veafCarrierOperations.logTrace("Pedro WP2 = " .. veaf.vecToString(pedroWaypoint2))
                traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "pedroWaypoint2", pedroWaypoint2, debugMarkersErasedAtEachStep)

                local mission = { 
                    id = 'Mission', 
                    params = { 
                        ["communication"] = false,
                        ["start_time"] = 0,
                        ["task"] = "Transport",
                        route = { 
                            points = { }
                        } 
                    } 
                }

                if pedroWaypoint1 then 
                    mission.params.route.points = {
                        [1] = 
                        {
                            ["alt"] = 35,
                            ["action"] = "Turning Point",
                            ["alt_type"] = "BARO",
                            ["speed"] = 50,
                            ["type"] = "Turning Point",
                            ["x"] = pedroUnit:getPosition().p.x,
                            ["y"] = pedroUnit:getPosition().p.z,
                            ["speed_locked"] = true,
                        },
                        [2] = { 
                            ["type"] = "Turning Point",
                            ["action"] = "Turning Point",
                            ["x"] = pedroWaypoint1.x,
                            ["y"] = pedroWaypoint1.z,
                            ["alt"] = 35, -- in meters
                            ["alt_type"] = "BARO", 
                            ["speed"] = 50,
                            ["speed_locked"] = true, 
                        },
                        [3] = { 
                            ["type"] = "Turning Point",
                            ["action"] = "Turning Point",
                            ["x"] = pedroWaypoint2.x,
                            ["y"] = pedroWaypoint2.z,
                            ["alt"] = 35, -- in meters
                            ["alt_type"] = "BARO", 
                            ["speed"] = speed,  -- speed in m/s
                            ["speed_locked"] = true, 
                        },
                    } 
                else
                    mission.params.route.points = {
                        [1] = 
                        {
                            ["alt"] = 35,
                            ["action"] = "Turning Point",
                            ["alt_type"] = "BARO",
                            ["speed"] = 50,
                            ["type"] = "Turning Point",
                            ["x"] = pedroUnit:getPosition().p.x,
                            ["y"] = pedroUnit:getPosition().p.z,
                            ["speed_locked"] = true,
                        },
                        [2] = { 
                            ["type"] = "Turning Point",
                            ["action"] = "Turning Point",
                            ["x"] = pedroWaypoint2.x,
                            ["y"] = pedroWaypoint2.z,
                            ["alt"] = 35, -- in meters
                            ["alt_type"] = "BARO", 
                            ["speed"] = speed,  -- speed in m/s
                            ["speed_locked"] = true, 
                        },
                    } 
                end

                -- replace whole mission
                veafCarrierOperations.logDebug("Setting Pedro mission")
                local controller = pedroGroup:getController()
                controller:setTask(mission)

            end
        end


        -- check if a S3B-Tanker group exists for this carrier
        if not(mist.getGroupData(carrier.tankerGroupName)) then
            veafCarrierOperations.logInfo("No Tanker group named " .. carrier.tankerGroupName)
        else

            local routeTanker = (carrierDistanceFromInitialPosition > 18520)
            carrier.tankerRouteSet = carrier.tankerRouteSet + 1
            if carrier.tankerRouteSet <= 2 then
                -- prepare or correct the Tanker route (8000ft high, 10nm aft and 4nm to the starboard side of the carrier, refueling on BRC)
                local tankerUnit = Unit.getByName(carrier.tankerGroupName)
                if (tankerUnit) then
                    veafCarrierOperations.logDebug("found Tanker unit")
                    -- check if unit is still alive
                    if tankerUnit:getLife() < 1 then
                        tankerUnit = nil -- respawn when damaged
                    end
                end
                
                -- spawn if needed
                if not(tankerUnit and carrier.tankerIsSpawned) then
                    veafCarrierOperations.logDebug("respawning Tanker unit")
                    mist.respawnGroup(carrier.tankerGroupName, true)
                    carrier.tankerIsSpawned = true
                end

                tankerUnit = Unit.getByName(carrier.tankerGroupName)
                local tankerGroup = Group.getByName(carrier.tankerGroupName) -- group has the same name as the unit
                if (tankerGroup) then
                    veafCarrierOperations.logDebug("found Tanker group")
                    veafCarrierOperations.logTrace("groupName="..tankerGroup:getName())
                    
                    -- waypoint #1 is 5nm to port, 5nm to the front
                    local offsetPointOnLand, offsetPoint = veaf.computeCoordinatesOffsetFromRoute(startPosition, newWaypoint, 9000, 9000)
                    local tankerWaypoint1 = offsetPoint
                    veafCarrierOperations.logTrace("Tanker WP1 = " .. veaf.vecToString(tankerWaypoint1))
                    veafCarrierOperations.cleanupLogMarkers(debugMarkersForTanker)
                    traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "tankerWaypoint1", tankerWaypoint1, debugMarkersForTanker)

                    -- waypoint #2 is 20nm ahead of waypoint #2, on BRC
                    local offsetPointOnLand, offsetPoint = veaf.computeCoordinatesOffsetFromRoute(startPosition, newWaypoint, 37000 + 9000, 9000)
                    local tankerWaypoint2 = offsetPoint
                    veafCarrierOperations.logTrace("Tanker WP2 = " .. veaf.vecToString(tankerWaypoint2))
                    traceMarkerId = veafCarrierOperations.logMarker(traceMarkerId, "tankerWaypoint2", tankerWaypoint2, debugMarkersForTanker)

                    local mission = { 
                        id = 'Mission', 
                        params = { 
                            ["communication"] = true,
                            ["start_time"] = 0,
                            ["task"] = "Refueling",
                            ["taskSelected"] = true,
                            ["route"] = 
                            {
                                ["points"] = 
                                {
                                    [1] = 
                                    {
                                        ["alt"] = 2500,
                                        ["action"] = "Turning Point",
                                        ["alt_type"] = "BARO",
                                        ["speed"] = 110,
                                        ["type"] = "Turning Point",
                                        ["x"] = startPosition.x,
                                        ["y"] = startPosition.z,
                                        ["speed_locked"] = true,
                                    },
                                    [2] = 
                                    {
                                        ["alt"] = 2500,
                                        ["action"] = "Turning Point",
                                        ["alt_type"] = "BARO",
                                        ["speed"] = 110,
                                        ["task"] = 
                                        {
                                            ["id"] = "ComboTask",
                                            ["params"] = 
                                            {
                                                ["tasks"] = 
                                                {
                                                    [1] = 
                                                    {
                                                        ["enabled"] = true,
                                                        ["auto"] = true,
                                                        ["id"] = "Tanker",
                                                        ["number"] = 1,
                                                    }, -- end of [1]
                                                    [2] = 
                                                    {
                                                        ["enabled"] = true,
                                                        ["auto"] = true,
                                                        ["id"] = "WrappedAction",
                                                        ["number"] = 2,
                                                        ["params"] = 
                                                        {
                                                            ["action"] = 
                                                            {
                                                                ["id"] = "ActivateBeacon",
                                                                ["params"] = 
                                                                {
                                                                    ["type"] = 4,
                                                                    ["AA"] = true,
                                                                    ["unitId"] = tankerUnit:getID(),
                                                                    ["modeChannel"] = "Y",
                                                                    ["system"] = 5,
                                                                    ["callsign"] = "T74",
                                                                    ["channel"] = 75, -- TODO make the Tacan dynamic
                                                                    ["bearing"] = true,
                                                                    ["frequency"] = 1036000000,
                                                                }, -- end of ["params"]
                                                            }, -- end of ["action"]
                                                        }, -- end of ["params"]
                                                    }, -- end of [2]
                                                }, -- end of ["tasks"]
                                            }, -- end of ["params"]
                                        }, -- end of ["task"]
                                        ["type"] = "Turning Point",
                                        ["ETA"] = 0,
                                        ["ETA_locked"] = true,
                                        ["x"] = startPosition.x,
                                        ["y"] = startPosition.z,
                                        ["speed_locked"] = true,
                                    },
                                    [3] = 
                                    {
                                        ["alt"] = 2500,
                                        ["action"] = "Turning Point",
                                        ["alt_type"] = "BARO",
                                        ["speed"] = 110,
                                        ["task"] = 
                                        {
                                            ["id"] = "ComboTask",
                                            ["params"] = 
                                            {
                                                ["tasks"] = 
                                                {
                                                    [1] = 
                                                    {
                                                        ["enabled"] = true,
                                                        ["auto"] = false,
                                                        ["id"] = "Orbit",
                                                        ["number"] = 1,
                                                        ["params"] = 
                                                        {
                                                            ["altitude"] = 2500,
                                                            ["pattern"] = "Race-Track",
                                                            ["speed"] = 110,
                                                        }, -- end of ["params"]
                                                    }, -- end of [1]
                                                }, -- end of ["tasks"]
                                            }, -- end of ["params"]
                                        }, -- end of ["task"]
                                        ["type"] = "Turning Point",
                                        ["x"] = tankerWaypoint1.x,
                                        ["y"] = tankerWaypoint1.z,
                                        ["speed_locked"] = true,
                                    },
                                    [4] = 
                                    {
                                        ["alt"] = 2500,
                                        ["action"] = "Turning Point",
                                        ["alt_type"] = "BARO",
                                        ["speed"] = 110,
                                        ["type"] = "Turning Point",
                                        ["x"] = tankerWaypoint2.x,
                                        ["y"] = tankerWaypoint2.z,
                                        ["speed_locked"] = true,
                                    }, -- end of [3]
                                }, -- end of ["points"]
                            }, -- end of ["route"]
                        }
                    }                

                    -- replace whole mission
                    veafCarrierOperations.logDebug("Setting Tanker mission")
                    local controller = tankerGroup:getController()
                    controller:setTask(mission)
                    carrier.tankerRouteIsSet = true

                end
            end
        end
    end   
end

--- Gets informations about current carrier operations
function veafCarrierOperations.getAtcForCarrierOperations(parameters)
    local groupName, groupId = unpack(parameters)
    veafCarrierOperations.logDebug("getAtcForCarrierOperations(".. groupName .. ")")

    local carrier = veafCarrierOperations.carriers[groupName]
    local carrierUnit = Unit.getByName(carrier.carrierUnitName)
    currentHeading = -1
    currentSpeed = -1
    if carrierUnit then 
        currentHeading = mist.utils.round(mist.utils.toDegree(mist.getHeading(carrierUnit)), 0)
        currentSpeed = mist.utils.round(mist.utils.mpsToKnots(mist.vec.mag(carrierUnit:getVelocity())),0)
    end

    if not(carrier) then
        local text = "Cannot find the carrier group "..groupName
        veafCarrierOperations.logError(text)
        trigger.action.outText(text, 5)
        return
    end

    local result = ""
    local groupPosition = veaf.getAvgGroupPos(groupName)
    
    if carrier.conductingAirOperations then
        local remainingTime = veaf.round((carrier.airOperationsEndAt - timer.getTime()) /60, 1)
        result = "The carrier group "..groupName.." is conducting air operations :\n" ..
        "  - Base Recovery Course : " .. carrier.heading .. " (true) at " .. carrier.speed .. " kn\n" ..
        "  - Remaining time : " .. remainingTime .. " minutes\n"
    else
        result = "The carrier group "..groupName.." is not conducting carrier air operations\n"
    end

    local startPosition = carrierUnit:getPosition().p
    startPosition = { x=startPosition.x, z=startPosition.z, y=startPosition.y + veafCarrierOperations.ALT_FOR_MEASURING_WIND} -- on deck, 50 meters above the water

    --get wind info
    local wind = atmosphere.getWind(startPosition)
    local windspeed = mist.vec.mag(wind)
    veafCarrierOperations.logTrace("windspeed="..windspeed.." m/s")

    --get wind direction sorted
    local winddir = veaf.round(math.atan2(wind.z, wind.x) * 180 / math.pi,0)
    if winddir < 0 then
        winddir = winddir + 360 --converts to positive numbers		
    end
    if winddir <= 180 then
        winddir = winddir + 180
    else
        winddir = winddir - 180
    end

    if currentHeading > -1 and currentSpeed > -1 then
        -- compute magnetic deviation at carrier position
        local magdev = veaf.round(mist.getNorthCorrection(startPosition) * 180 / math.pi,1)
        veafCarrierOperations.logTrace("magdev = " .. magdev)
        
        result = result ..
        "  - Current heading (true) " .. veaf.round(currentHeading - magdev, 0) .. "\n" ..
        "  - Current heading (mag)  " .. currentHeading .. "\n" ..
        "  - Current speed " .. currentSpeed .. " kn"
    end

    -- add wind information
    local windText =     'no wind.\n'
    if windspeed > 0 then
        windText = string.format('from %s at %s kn (%s m/s).\n', winddir, veaf.round(windspeed * 1.94384, 0), veaf.round(windspeed, 1))
    end
    result = result .. '\n - Wind ' .. windText

    trigger.action.outTextForGroup(groupId, result, 15)

end

--- Ends carrier operations ; changes the radio menu item to START and send the carrier back to its starting point
function veafCarrierOperations.stopCarrierOperations(groupName)
    veafCarrierOperations.logDebug("stopCarrierOperations(".. groupName .. ")")

    local carrier = veafCarrierOperations.carriers[groupName]

    if not(carrier) then
        local text = "Cannot find the carrier group "..groupName
        veafCarrierOperations.logError(text)
        trigger.action.outText(text, 5)
        return
    end

    -- make the carrier move to its initial position
    if carrier.initialPosition ~= nil then
	
        veafCarrierOperations.logTrace("carrier.initialPosition="..veaf.vecToString(carrier.initialPosition))

        local newWaypoint = {
            ["action"] = "Turning Point",
            ["form"] = "Turning Point",
            ["speed"] = 300,  -- ahead flank !
            ["type"] = "Turning Point",
            ["x"] = carrier.initialPosition.x,
            ["y"] = carrier.initialPosition.z,
        }

        -- order group to new waypoint
        mist.goRoute(groupName, {newWaypoint})

        local text = "The carrier group "..groupName.." has stopped air operations ; it's moving back to its initial position"
        veafCarrierOperations.logInfo(text)
        trigger.action.outText(text, 5)

        carrier.conductingAirOperations = false

        -- change the menu
        veafCarrierOperations.logTrace("change the menu")
        veafCarrierOperations.rebuildRadioMenu()
    end

    -- make the Pedro land
    if (carrier.pedroIsSpawned) then
        carrier.pedroIsSpawned = false
        local carrierUnit = Unit.getByName(carrier.carrierUnitName)
        local carrierPosition = carrierUnit:getPosition().p
        local pedroGroup = Group.getByName(carrier.pedroGroupName)
        if (pedroGroup) then
            veafCarrierOperations.logDebug("found Pedro group")

            local mission = { 
                id = 'Mission', 
                params = { 
                    ["communication"] = false,
                    ["start_time"] = 0,
                    ["task"] = "Transport",
                    route = { 
                        points = { 
                            [1] = { 
                                --["linkUnit"] = 2,
                                --["helipadId"] = 2,
                                ["type"] = "Land",
                                ["action"] = "Landing",
                                ["x"] = carrierPosition.x,
                                ["y"] = carrierPosition.z,
                                ["alt"] = 0,
                                ["alt_type"] = "BARO", 
                                ["speed"] = 50,  -- speed in m/s
                                ["speed_locked"] = true, 
                            }, -- enf of [1]
                        }
                    } 
                } 
            }

            -- replace whole mission
            veafCarrierOperations.logDebug("Setting Pedro mission")
            local controller = pedroGroup:getController()
            controller:setTask(mission)

            --veafCarrierOperations.logDebug("despawning Pedro unit")
            --pedroUnit:destroy()
        end
    end    

end

-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- Radio menu and help
-------------------------------------------------------------------------------------------------------------------------------------------------------------
--- Rebuild the radio menu
function veafCarrierOperations.rebuildRadioMenu()
    veafCarrierOperations.logDebug("veafCarrierOperations.rebuildRadioMenu()")

    -- find the carriers in the veafCarrierOperations.carriers table and prepare their menus
    for name, carrier in pairs(veafCarrierOperations.carriers) do
        veafCarrierOperations.logTrace("rebuildRadioMenu processing "..name)
        
        -- remove the start menu
        if carrier.startMenuName1 then
            veafCarrierOperations.logTrace("remove carrier.startMenuName1="..carrier.startMenuName1)
            veafRadio.delCommand(veafCarrierOperations.rootPath, carrier.startMenuName1)
        end
        if carrier.startMenuName2 then
            veafCarrierOperations.logTrace("remove carrier.startMenuName2="..carrier.startMenuName2)
            veafRadio.delCommand(veafCarrierOperations.rootPath, carrier.startMenuName2)
        end

        -- remove the stop menu
        if carrier.stopMenuName then
            veafCarrierOperations.logTrace("remove carrier.stopMenuName="..carrier.stopMenuName)
            veafRadio.delCommand(veafCarrierOperations.rootPath, carrier.stopMenuName)
        end

        -- remove the ATC menu (by player group)
        if carrier.getInfoMenuName then
            veafCarrierOperations.logTrace("remove carrier.getInfoMenuName="..carrier.getInfoMenuName)
            veafRadio.delCommand(veafCarrierOperations.rootPath, carrier.getInfoMenuName)
        end

        if carrier.conductingAirOperations then
            -- add the stop menu
            carrier.stopMenuName = name .. " - End air operations"
            veafCarrierOperations.logTrace("add carrier.stopMenuName="..carrier.stopMenuName)
            veafRadio.addCommandToSubmenu(carrier.stopMenuName, veafCarrierOperations.rootPath, veafCarrierOperations.stopCarrierOperations, name)
        else
            -- add the "start for veafCarrierOperations.MAX_OPERATIONS_DURATION" menu
            carrier.startMenuName1 = name .. " - Start carrier air operations for " .. veafCarrierOperations.MAX_OPERATIONS_DURATION .. " minutes"
            veafCarrierOperations.logTrace("add carrier.startMenuName1="..carrier.startMenuName1)
            veafRadio.addCommandToSubmenu(carrier.startMenuName1, veafCarrierOperations.rootPath, veafCarrierOperations.startCarrierOperations, { name, veafCarrierOperations.MAX_OPERATIONS_DURATION })

            -- add the "start for veafCarrierOperations.MAX_OPERATIONS_DURATION * 2" menu
            carrier.startMenuName2 = name .. " - Start carrier air operations for " .. veafCarrierOperations.MAX_OPERATIONS_DURATION * 2 .. " minutes"
            veafCarrierOperations.logTrace("add carrier.startMenuName2="..carrier.startMenuName2)
            veafRadio.addCommandToSubmenu(carrier.startMenuName2, veafCarrierOperations.rootPath, veafCarrierOperations.startCarrierOperations, { name, veafCarrierOperations.MAX_OPERATIONS_DURATION * 2 })
        end

        -- add the ATC menu (by player group)
        carrier.getInfoMenuName = name .. " - ATC - Request informations"
        veafCarrierOperations.logTrace("add carrier.getInfoMenuName="..carrier.getInfoMenuName)
        veafRadio.addCommandToSubmenu(carrier.getInfoMenuName, veafCarrierOperations.rootPath, veafCarrierOperations.getAtcForCarrierOperations, name, true)

        veafRadio.refreshRadioMenu()
    end
end

--- Build the initial radio menu
function veafCarrierOperations.buildRadioMenu()
    veafCarrierOperations.logDebug("veafCarrierOperations.buildRadioMenu")

    veafCarrierOperations.rootPath = veafRadio.addSubMenu(veafCarrierOperations.RadioMenuName)

    -- build HELP menu for each group
    veafRadio.addCommandToSubmenu("HELP", veafCarrierOperations.rootPath, veafCarrierOperations.help, true)

    -- find the carriers and add them to the veafCarrierOperations.carriers table, store its initial location and create the menus
    for name, group in pairs(mist.DBs.groupsByName) do
        veafCarrierOperations.logTrace("found group "..name)
        if name:match(veafCarrierOperations.CarrierGroupNamePattern) then
            veafCarrierOperations.carriers[name] = {}
            local carrier = veafCarrierOperations.carriers[name]
            veafCarrierOperations.logTrace("found carrier !")

            -- find the actual carrier unit
            local group = Group.getByName(name)
            local carrierUnit = nil
            for _, unit in pairs(group:getUnits()) do
                local unitType = unit:getDesc()["typeName"]
                for knownCarrierType, knownCarrierDeckAngle in pairs(veafCarrierOperations.AllCarriers) do
                    if unitType == knownCarrierType then
                        carrier.carrierUnitName = unit:getName()
                        carrier.deckAngle = knownCarrierDeckAngle
                        carrierUnit = unit -- temporary
                        break
                    end
                end
            end

            -- take note of the starting position, heading and speed
            carrier.initialPosition = veaf.getAvgGroupPos(name)
            veafCarrierOperations.logTrace("carrier.initialPosition="..veaf.vecToString(carrier.initialPosition))

        end
    end

    veafCarrierOperations.rebuildRadioMenu()
end

function veafCarrierOperations.help()
    local text =
        'Use the radio menus to start and end carrier operations\n' ..
        'START: carrier will find out the wind and set sail at optimum speed to achieve a 25kn headwind\n' ..
        '       the radio menu will show the recovery course and TACAN information\n' ..
        'END  : carrier will go back to its starting point (where it was when the START command was issued)\n' ..
        'RESET: carrier will go back to where it was when the mission started'

    trigger.action.outText(text, 30)
end

--- This function is called at regular interval (see veafCarrierOperations.SCHEDULER_INTERVAL) and manages the carrier operations schedules
--- It will make any carrier group that has started carrier operations maintain a correct course for recovery, even if wind changes.
--- Also, it will stop carrier operations after a set time (see veafCarrierOperations.MAX_OPERATIONS_DURATION).
function veafCarrierOperations.operationsScheduler()
    veafCarrierOperations.logDebug("veafCarrierOperations.operationsScheduler()")

    -- find the carriers in the veafCarrierOperations.carriers table and check if they are operating
    for name, carrier in pairs(veafCarrierOperations.carriers) do
        veafCarrierOperations.logDebug("checking " .. name)
        if carrier.conductingAirOperations then
            veafCarrierOperations.logDebug(name .. " is conducting operations ; checking course and ops duration")
            if carrier.airOperationsEndAt < timer.getTime() then
                -- time to stop operations
                veafCarrierOperations.logInfo(name .. " has been conducting operations long enough ; stopping ops")
                veafCarrierOperations.stopCarrierOperations(name)
            else
                local remainingTime = veaf.round((carrier.airOperationsEndAt - timer.getTime()) /60, 1)
                veafCarrierOperations.logDebug(name .. " will continue conducting operations for " .. remainingTime .. " more minutes")
                -- check and reset course
                veafCarrierOperations.continueCarrierOperations(name)
            end
        else
            veafCarrierOperations.logDebug(name .. " is not conducting operations")
        end
    end

    veafCarrierOperations.logDebug("veafCarrierOperations.operationsScheduler() - rescheduling in " .. veafCarrierOperations.SCHEDULER_INTERVAL * 60 .. " s")
    mist.scheduleFunction(veafCarrierOperations.operationsScheduler,{},timer.getTime() + veafCarrierOperations.SCHEDULER_INTERVAL * 60)
end

------------------------------------------------------------------------------------------------------------------------------------------------------------
-------------------------------------------------------------------------------------------------------------------------------------------------------------
-- initialisation
-------------------------------------------------------------------------------------------------------------------------------------------------------------

function veafCarrierOperations.initialize()
    veafCarrierOperations.buildRadioMenu()
    veafCarrierOperations.operationsScheduler()
end

veafCarrierOperations.logInfo(string.format("Loading version %s", veafCarrierOperations.Version))

--- Enable/Disable error boxes displayed on screen.
env.setErrorMessageBoxEnabled(false)



