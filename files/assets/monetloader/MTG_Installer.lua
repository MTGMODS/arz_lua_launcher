---@diagnostic disable: undefined-global, need-check-nil, lowercase-global, cast-local-type, unused-local

script_name("MTG Helper Installer")
script_author("MTG MODS")
script_version("1.0")
script_description('Installer Arizona&Rodina Helper')

require("lib.moonloader")
local effil = require('effil')

local worked_dir = getWorkingDirectory():gsub('\\','/')
local helper_path = worked_dir .. "/Arizona Helper.lua"
local helper_url = 'https://github.com/MTGMODS/arizona-helper/raw/refs/heads/main/Arizona%20Helper.lua'

function msg(text)
    sampAddChatMessage('{00ccff}[MTG Helper Installer] {ffffff}' .. text, -1)
end

function downloadToFile(url, path, callback, progressInterval)
	callback = callback or function() end
	progressInterval = progressInterval or 0.1

	local progressChannel = effil.channel(0)

	local runner = effil.thread(function(url, path)
	local http = require("socket.http")
	local ltn = require("ltn12")

	local r, c, h = http.request({
		method = "HEAD",
		url = url,
	})

	if c ~= 200 then
		return false, c
	end
	local total_size = h["content-length"]

	local f = io.open(path, "wb")
	if not f then
		return false, "failed to open file"
	end
	local success, res, status_code = pcall(http.request, {
		method = "GET",
		url = url,
		sink = function(chunk, err)
		local clock = os.clock()
		if chunk and not lastProgress or (clock - lastProgress) >= progressInterval then
			progressChannel:push("downloading", f:seek("end"), total_size)
			lastProgress = os.clock()
		elseif err then
			progressChannel:push("error", err)
		end

		return ltn.sink.file(f)(chunk, err)
		end,
	})

	if not success then
		return false, res
	end

	if not res then
		return false, status_code
	end

	return true, total_size
	end)
	local thread = runner(url, path)

	local function checkStatus()
	local tstatus = thread:status()
	if tstatus == "failed" or tstatus == "completed" then
		local result, value = thread:get()

		if result then
		callback("finished", value)
		else
		callback("error", value)
		end

		return true
	end
	end

	lua_thread.create(function()
	if checkStatus() then
		return
	end

	while thread:status() == "running" do
		if progressChannel:size() > 0 then
		local type, pos, total_size = progressChannel:pop()
		callback(type, pos, total_size)
		end
		wait(0)
	end

	checkStatus()
	end)
end

function main()

    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(0) end
	repeat wait(0) until sampIsLocalPlayerSpawned()

	if not doesFileExist(helper_path) then
		msg('Используйте команду {00ccff}/mtg {ffffff}для авто-установки {00ccff}Arizona&Rodina Helper')
	end

    sampRegisterChatCommand('mtg', function ()
		if doesFileExist(helper_path) then
			msg('У вас уже установлен хелпер, открываю его главное меню...')
			sampProcessChatInput('/helper')
		else
			msg('Начинаю скачивание хелпера, ожидайте...')
			downloadToFile(helper_url, helper_path, function(type, pos, total_size)
				if type == "finished" then
					lua_thread.create(function ()
						msg('Скачивание хелпера успешно завершено! Перезапуск скриптов...')
						wait(500)
						reloadScripts()
					end)
				elseif type == "error" then
					msg('Ошибка скачивания хелпера: ' .. pos)
					msg('Возможно вам поможет VPN или другой интернет.')
				end
			end)
		end
	end)

    wait(-1)

end