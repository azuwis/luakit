--- Simple URI-based content filter.
--
-- This is a simple, fast ad blocker module that works by blocking requests to
-- domains that only serve advertisements. It does not currently do any form of
-- cosmetic ad blocking (i.e. element hiding with CSS).
--
-- ### Usage
--
-- * Add `require "adblock"` and `require "adblock_chrome"` to your `config.rc`.
-- * Download AdblockPlus-compatible filter lists to `$XDG_DATA_HOME/luakit/adblock`.
--   Multiple lists are supported.
--   EasyList is the most popular Adblock Plus filter list, and can be
--   downloaded from [https://easylist.to/](https://easylist.to/).
-- * Filterlists need to be updated regularly (~weekly), use cron!
--
-- @module adblock
-- @author Chris van Dijk (quigybo) (quigybo@hotmail.com)
-- @author Mason Larobina (mason-l) (mason.larobina@gmail.com)
-- @author Plaque FCC (Reslayer@ya.ru)
-- @copyright 2010 Chris van Dijk (quigybo) (quigybo@hotmail.com)
-- @copyright 2010 Mason Larobina (mason-l) (mason.larobina@gmail.com)
-- @copyright 2012 Plaque FCC (Reslayer@ya.ru)

local webview   = require("webview")
local window    = require("window")
local lousy     = require("lousy")
local util      = lousy.util
local capi      = { luakit = luakit }
local lfs       = require("lfs")
local binds     = require("binds")
local add_cmds  = binds.add_cmds

local _M = {}

local adblock_wm = require_web_module("adblock_wm")

--- Whether ad blocking is enabled.
-- @readonly
-- @type boolean
_M.enabled = true

-- Adblock Plus compatible filter lists.
local adblock_dir = capi.luakit.data_dir .. "/adblock/"
local filterfiles = {}
local subscriptions_file = adblock_dir .. "/subscriptions"

--- The set of ad blocking subscriptions that are active.
-- @type table
-- @readonly
_M.subscriptions = {}

--- String patterns to filter URIs with.
-- @type table
-- @readonly
_M.rules = {}

--- Fitting for adblock.chrome.refresh_views()
-- @local
_M.refresh_views = function()
    -- Dummy.
end

--- Enable ad blocking.
_M.enable = function ()
    _M.enabled = true
    adblock_wm:emit_signal("enable", true)
    _M.refresh_views()
end

--- Disable ad blocking.
_M.disable = function ()
    _M.enabled = false
    adblock_wm:emit_signal("enable", false)
    _M.refresh_views()
end

--- Report AdBlock state.
-- @treturn[1] string "Enabled" if ad blocking is enabled
-- @treturn[2] string "Disabled" if ad blocking is disabled
_M.state = function ()
    return _M.enabled and "Enabled" or "Disabled"
end

-- Detect files to read rules from
local function detect_files()
    -- Create adblock directory if it doesn't exist
    local curdir = lfs.currentdir()
    if not lfs.chdir(adblock_dir) then
        lfs.mkdir(adblock_dir)
    else
        lfs.chdir(curdir)
    end

    -- Look for filters lists:
    for filename in lfs.dir(adblock_dir) do
        if string.find(filename, "%.txt$") then
            msg.verbose("adblock: Found adblock list: " .. filename)
            table.insert(filterfiles, filename)
        end
    end

    msg.info("adblock: Found " .. #filterfiles .. " rules lists")
end

local function get_abp_opts(s)
    local opts = {}
    local pos = string.find(s, "%$")
    if pos then
        local op = string.sub(s, pos+1)
        s = string.sub(s, 1, pos-1)
        for key in string.gmatch(op, "[^,]+") do
            local val
            local p = string.find(key, "=")
            if p then
                val = string.sub(key, p+1)
                key = string.sub(key, 1, p-1)
            end

            local negative = false
            if string.sub(key, 1, 1) == "~" then
                negative = true
                key = string.sub(key, 2)
            end

            if key == "domain" and val then
                local domains = {}
                for v in string.gmatch(val, "[^|]+") do
                    table.insert(domains, v)
                end
                if #domains > 0 then opts["domain"] = domains end
            elseif key == "third-party" then
                opts["third-party"] = not negative
            else
                opts["unknown"] = true
            end
        end
    end
    return s, opts
end

-- Convert Adblock Plus filter description to lua string pattern
-- See http://adblockplus.org/en/filters for more information
local abp_to_pattern = function (s)
    -- Strip filter options
    local opts
    s, opts = get_abp_opts(s)
    if opts and opts.unknown == true then return {} end -- Skip rules with unknown options

    local domain = nil

    if string.len(s) > 0 then
        -- If this is matchable as a plain string, return early
        local has_star = string.find(s, "*", 1, true)
        local has_caret = string.find(s, "^", 1, true)
        local domain_anchor = string.match(s, "^||")
        if not has_star and not has_caret and not domain_anchor then
            return {s}, opts, nil, true
        end

        -- Optimize for domain anchor rules
        if string.match(s, "^||") then
            -- Extract the domain from the pattern
            local d = string.sub(s, 3)
            d = string.gsub(d, "/.*", "")
            d = string.gsub(d, "%^.*", "")

            -- We don't bother with wildcard domains since they aren't frequent enough
            if not string.find(d, "*") then
                domain = d
            end
        end

        -- Protect magic characters (^$()%.[]*+-?) not used by ABP (^$()[]*)
        s = string.gsub(s, "([%%%.%+%-%?])", "%%%1")

        -- Wildcards are globbing
        s = string.gsub(s, "%*", "%.%*")

        -- Caret is separator (anything but a letter, a digit, or one of the following:Â - . %)
        s = string.gsub(s, "%^", "[^%%w%%-%%.%%%%]")

        if domain_anchor then
            local p = string.sub(s, 3) -- Clip off first two || characters
            s = { "^https?://" .. p, "^https?://[^/]*%." .. p }
        else
            s = { s }
        end

        for k, v in ipairs(s) do
            -- Pipe is anchor
            v = string.gsub(v, "^|", "%^")
            v = string.gsub(v, "|$", "%$")

            -- Convert to lowercase ($match-case option is not honoured)
            v = string.lower(v)
            s[k] = v
        end
    end

    return s, opts, domain, false
end

local add_unique_cached = function (pattern, opts, tab, cache_tab)
    if cache_tab[pattern] then
        return false
    else
        --cache_tab[pattern], tab[pattern] = true, pattern
        cache_tab[pattern], tab[pattern] = true, opts
        return true
    end
end

local list_new = function ()
    return {
        patterns    = {},
        ad_patterns = {},
        plain       = {},
        ad_plain    = {},
        domains     = {},
        length      = 0,
        ignored     = 0,
    }
end

local list_add = function(list, line, cache, pat_exclude)
    local pats, opts, domain, plain = abp_to_pattern(line)
    local contains_ad = string.find(line, "ad", 1, true)

    for _, pat in ipairs(pats) do
        local new
        if plain then
            local bucket = contains_ad and list.ad_plain or list.plain
            new = add_unique_cached(pat, opts, bucket, cache)
        elseif pat ~= "^http:" and pat ~= pat_exclude then
            if domain then
                if not list.domains[domain] then
                    list.domains[domain] = {}
                end
                new = add_unique_cached(pat, opts, list.domains[domain], cache)
            else
                local bucket = contains_ad and list.ad_patterns or list.patterns
                new = add_unique_cached(pat, opts, bucket, cache)
            end
        end
        if new then
            list.length = list.length + 1
        else
            list.ignored = list.ignored + 1
        end
    end
end

-- Parses an Adblock Plus compatible filter list
local parse_abpfilterlist = function (filters_dir, filename, cache)
    if os.exists(filters_dir .. filename) then
        msg.verbose("adblock: loading filterlist %s", filename)
    else
        msg.warn("adblock: error loading filter list (%s: No such file or directory)", filename)
    end
    filename = filters_dir .. filename

    local white, black = list_new(), list_new()
    for line in io.lines(filename) do
        -- Ignore comments, header and blank lines
        if line:match("^[![]") or line:match("^$") or line:match("^# ") or line:match("^#$") then
            -- dammitwhydoesntluahaveacontinuestatement
        -- Ignore element hiding
        elseif line:match("##") or line:match("#@#") then
            --icnt = icnt + 1
        elseif line:match("^@@") then
            list_add(white, string.sub(line, 3), cache.white)
        else
            list_add(black, line, cache.black, ".*")
        end
    end

    local wlen, blen, icnt = white.length, black.length, white.ignored + black.ignored

    return white, black, wlen, blen, icnt
end

--- Save the in-memory subscriptions to flatfile.
-- @param file The destination file or the default location if nil.
local function write_subscriptions(file)
    if not file then file = subscriptions_file end
    assert(file and file ~= "", "Cannot write subscriptions to empty path")

    local lines = {}
    for _, list in pairs(_M.subscriptions) do
        local subs = { uri = list.uri, title = list.title, opts = table.concat(list.opts or {}, " "), }
        local line = string.gsub("{title}\t{uri}\t{opts}", "{(%w+)}", subs)
        table.insert(lines, line)
    end

    -- Write table to disk
    local fh = io.open(file, "w")
    fh:write(table.concat(lines, "\n"))
    io.close(fh)
end

-- Remove options and add new ones to list
-- @param list_index Index of the list to modify
-- @param opt_ex Options to exclude
-- @param opt_inc Options to include
local function list_opts_modify(list_index, opt_ex, opt_inc)
    assert(type(list_index) == "number", "list options modify: invalid list index")
    assert(list_index > 0, "list options modify: index has to be > 0")
    if not opt_ex then opt_ex = {} end
    if not opt_inc then opt_inc = {} end

    if type(opt_ex) == "string" then opt_ex = util.string.split(opt_ex) end
    if type(opt_inc) == "string" then opt_inc = util.string.split(opt_inc) end

    local list = util.table.values(_M.subscriptions)[list_index]
    local opts = opt_inc
    for _, opt in ipairs(list.opts) do
        if not util.table.hasitem(opt_ex, opt) then
            table.insert(opts, opt)
        end
    end

    -- Manage list's rules
    if util.table.hasitem(opt_inc, "Enabled") then
        adblock_wm:emit_signal("list_set_enabled", list.title, true)
        _M.refresh_views()
    elseif util.table.hasitem(opt_inc, "Disabled") then
        adblock_wm:emit_signal("list_set_enabled", list.title, false)
        _M.refresh_views()
    end

    list.opts = opts
    write_subscriptions()
end

--- Add a list to the in-memory lists table
local function add_list(uri, title, opts, replace, save_lists)
    assert( (title ~= nil) and (title ~= ""), "adblock list add: no title given")
    if not opts then opts = {} end

    -- Create tags table from string
    if type(opts) == "string" then opts = util.string.split(opts) end
    if table.maxn(opts) == 0 then table.insert(opts, "Disabled") end
    if not replace and _M.subscriptions[title] then
        local list = _M.subscriptions[title]
        -- Merge tags
        for _, opt in ipairs(opts) do
            if not util.table.hasitem(list, opt) then table.insert(list, opt) end
        end
    else
        -- Insert new adblock list
        local list = { uri = uri, title = title, opts = opts }
        if not (title == "" or title == nil) then
            _M.subscriptions[title] = list
        end
    end

    -- Save by default
    if save_lists ~= false then write_subscriptions() end
end

--- Load subscriptions from a flatfile to memory.
-- @param file The subscriptions file or the default subscriptions location if nil.
local function read_subscriptions(file)
    -- Find a subscriptions file
    if not file then file = subscriptions_file end
    if not os.exists(file) then
        msg.info(string.format("Subscriptions file '%s' doesn't exist", file))
        return
    end

    -- Read lines into subscriptions data table
    for line in io.lines(file) do
        local title, uri, opts = unpack(util.string.split(line, "\t"))
        if title ~= "" then add_list(uri, title, opts, false, false) end
    end
end

--- Load filter list files, and refresh any adblock pages that are open.
-- @tparam boolean reload True if all subscriptions already loaded
-- should be fully reloaded.
-- @tparam string single_list Single list file.
-- @tparam boolean no_sync True if subscriptions should not be synchronized to
-- the web process.
_M.load = function (reload, single_list, no_sync)
    if reload then _M.subscriptions, filterfiles = {}, {} end
    detect_files()
    if not single_list then
        read_subscriptions()
        local files_list = {}
        for _, filename in ipairs(filterfiles) do
            local list = _M.subscriptions[filename]
            if list and util.table.hasitem(list.opts, "Enabled") then
                table.insert(files_list, filename)
            else
                add_list(list and list.uri or "", filename, "Enabled", true, false)
            end
        end
        filterfiles = files_list
        -- Yes we may have changed subscriptions and even fixed something with them.
        write_subscriptions()
    end

    -- [re-]loading:
    if reload then _M.rules = {} end
    local filters_dir = adblock_dir
    local filterfiles_loading
    if single_list and not reload then
        filterfiles_loading = { single_list }
    else
        filterfiles_loading = filterfiles
    end
    local rules_cache = {
        black = {},
        white = {}
    } -- This cache should let us avoid unnecessary filters duplication.

    for _, filename in ipairs(filterfiles_loading) do
        local white, black, wlen, blen, icnt = parse_abpfilterlist(filters_dir, filename, rules_cache)
        local list = _M.subscriptions[filename]
        if not util.table.hasitem(_M.rules, list) then
            _M.rules[filename] = list
        end
        list.title, list.white, list.black, list.ignored = filename, wlen or 0, blen or 0, icnt or 0
        list.whitelist, list.blacklist = white or {}, black or {}
    end

    if not no_sync and not single_list then
        adblock_wm:emit_signal("update_rules", _M.rules)
    end
    _M.refresh_views()
end

--- Enable or disable an adblock filter list.
-- @tparam number|string a The number of the list to enable or disable.
-- @tparam boolean enabled True to enable, false to disable.
function _M.list_set_enabled(a, enabled)
    if enabled then
        list_opts_modify(tonumber(a), "Disabled", "Enabled")
    else
        list_opts_modify(tonumber(a), "Enabled", "Disabled")
    end
end

webview.add_signal("init", function (view)
    webview.modify_load_block(view, "adblock", true)
end)
adblock_wm:add_signal("rules_updated", function (_, web_process_id)
    for _, ww in pairs(window.bywidget) do
        for _, v in pairs(ww.tabs.children) do
            if v.web_process_id == web_process_id then
                webview.modify_load_block(v, "adblock", false)
            end
        end
    end
end)

capi.luakit.add_signal("web-extension-created", function (view)
    adblock_wm:emit_signal(view, "update_rules", _M.rules)
end)

webview.add_signal("init", function (view)
    view:add_signal("web-extension-loaded", function(v)
        for name, list in pairs(_M.rules) do
            local enabled = util.table.hasitem(list.opts, "Enabled")
            adblock_wm:emit_signal(v, "list_set_enabled", name, enabled)
        end
    end)
end)

-- Add commands.
local cmd = lousy.bind.cmd
add_cmds({
    cmd({"adblock-reload", "abr"}, "Reload adblock filters.", function (w)
        _M.load(true)
        w:notify("adblock: Reloading filters complete.")
    end),

    cmd({"adblock-list-enable", "able"}, "Enable an adblock filter list.", function (_, a)
        _M.list_set_enabled(a, true)
    end),

    cmd({"adblock-list-disable", "abld"}, "Disable an adblock filter list.", function (_, a)
        _M.list_set_enabled(a, false)
    end),

    cmd({"adblock-enable", "abe"}, "Enable ad blocking.", function ()
        _M.enable()
    end),

    cmd({"adblock-disable", "abd"}, "Disable ad blocking.", function ()
        _M.disable()
    end),
})

-- Initialise module
_M.load(nil, nil, true)

return _M

-- vim: et:sw=4:ts=8:sts=4:tw=80
