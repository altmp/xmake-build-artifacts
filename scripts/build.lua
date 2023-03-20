import("core.base.option")
import("core.base.json")
import("core.base.semver")
import("core.tool.toolchain")
import("lib.detect.find_tool")

local options =
{
    {'p', "plat",      "kv", os.host(), "Set platform"},
    {'a', "arch",      "kv", os.arch(), "Set architecture"},
    {'k', "kind",      "kv", nil,       "Set kind"},
    {'f', "configs",   "kv", nil,       "Set configs"},
    {nil, "vs",        "kv", nil,       "The Version of Visual Studio"},
    {nil, "vs_toolset","kv", nil,       "The Toolset Version of Visual Studio"},
    {nil, "vs_sdkver", "kv", nil,       "The Windows SDK Version of Visual Studio"}
}

function shallowcopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in pairs(orig) do
            copy[orig_key] = orig_value
        end
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

function build_artifacts(name, version, opt)
    local argv = {"lua", "private.xrepo", "install", "-yvD", "--shallow", "--force", "--build", "--linkjobs=2", "-p", opt.plat, "-a", opt.arch, "-k", opt.kind}
    if opt.configs then
        table.insert(argv, "-f")
        table.insert(argv, opt.configs)
    end
    if opt.vs then
        table.insert(argv, "--vs=" .. opt.vs)
    end
    if opt.vs_toolset then
        table.insert(argv, "--vs_toolset=" .. opt.vs_toolset)
    end
    if opt.vs_sdkver then
        table.insert(argv, "--vs_sdkver=" .. opt.vs_sdkver)
    end
    table.insert(argv, name .. " " .. version)
    os.execv("xmake", argv)
end

function get_buildid_for_msvc(buildhash, opt)
    local msvc = toolchain.load("msvc", {plat = opt.plat, arch = opt.arch})
    assert(msvc:check(), "msvc not found!")
    local vcvars = assert(msvc:config("vcvars"), "vcvars not found!")
    local vs_toolset = vcvars.VCToolsVersion
    if vs_toolset and semver.is_valid(vs_toolset) then
        assert(vs_toolset == "14.16.27023" or
               vs_toolset == "14.29.30133" or
               vs_toolset == "14.34.31933", "vs_toolset has been updated to %s", vs_toolset)
        local vs_toolset_semver = semver.new(vs_toolset)
        local msvc_version = "vc" .. vs_toolset_semver:major() .. tostring(vs_toolset_semver:minor()):sub(1, 1)
        return opt.plat .. "-" .. opt.arch .. "-" .. msvc_version .. "-" .. buildhash
    end
end

function export_artifacts(name, version, opt, cachekey)
    local argv = {"lua", "private.xrepo", "export", "-yD", "--shallow", "-p", opt.plat, "-a", opt.arch, "-k", opt.kind}
    if opt.configs then
        table.insert(argv, "-f")
        table.insert(argv, opt.configs)
    end
    table.insert(argv, "-o")
    table.insert(argv, "artifacts")
    table.insert(argv, name .. " " .. version)
    os.tryrm("artifacts")
    os.execv("xmake", argv)
    local buildhash
    for _, dir in ipairs(os.dirs(path.join("artifacts", "*", "*", "*", "*"))) do
        buildhash = path.filename(dir)
        break
    end
    assert(buildhash, "buildhash not found!")
    local oldir = os.cd("artifacts")
    local artifactfile
    if opt.plat == "windows" then
        local buildid = get_buildid_for_msvc(buildhash, opt)
        artifactfile = buildid .. "-" .. cachekey .. ".7z"
        local z7 = assert(find_tool("7z"), "7z not found!")
        os.execv(z7.program, {"a", artifactfile, "*"})
    else
        raise("unknown platform: %s", opt.plat)
    end
    return artifactfile
end

function cachehash(name, version, opt)
    key = name .. "-" .. version  .. "-" .. opt.kind .. "-" .. opt.plat .. "-" .. opt.arch .. "-" .. opt.configs
    print("Cache key full: " .. key)
    return hash.uuid4(key):gsub('-', ''):lower()
end

function build(name, version, opt)
    print("Starting build of " .. name .. " " .. version  .. " " .. opt.kind .. " " .. opt.plat .. " " .. opt.arch .. " " .. opt.configs)

    local cachekey = cachehash(name, version, opt)
    print("Cache key: " .. cachekey)

    local cachefile = path.join("packages", name:sub(1, 1), name, version, "cache.json")
    if os.exists(cachefile) then
        local cache = json.loadfile(cachefile)
        for _, entry in ipairs(cache) do
            if entry == cachekey then
                print("Package exists in cache, skipping")
                return
            end
        end
    end

    build_artifacts(name, version, opt)
    local artifactfile = export_artifacts(name, version, opt, cachekey)
    local tag = name .. "-" .. version
    local found = try {function () os.execv("gh", {"release", "view", tag}); return true end}
    if found then
        try {function () os.execv("gh", {"release", "upload", "--clobber", tag, artifactfile}) end}
    else
        local created = try {function () os.execv("gh", {"release", "create", "--notes", tag .. " artifacts", tag, artifactfile}); return true end}
        if not created then
            try {function() os.execv("gh", {"release", "upload", "--clobber", tag, artifactfile}) end}
        end
    end
end

function main(...)
    local opt = option.parse(table.pack(...), options, "Build artifacts.", "", "Usage: xmake l scripts/build.lua [options]")
    local buildpackages = json.loadfile(path.join(os.scriptdir(), "..", "packages.json"))

    for _, pkg in ipairs(buildpackages) do
        local name = pkg[1]
        local version = pkg[2]
        local pkgopt = shallowcopy(opt)
    
        if pkg[3] then
            if pkgopt.configs then
                pkgopt.configs = pkgopt.configs .. "," .. pkg[3]
            else
                pkgopt.configs = pkg[3]
            end
        end

        build(name, version, pkgopt)
        -- local artifactfile = build(name, version, pkgopt)
    end
end