import("core.base.option")
import("core.base.json")
import("core.tool.toolchain")
import("net.http")

function get_manifestkey(manifest)
    local key = ""
    for _, k in ipairs(table.orderkeys(manifest)) do
        key = key .. manifest[k].urls .. manifest[k].sha256
    end
    return key
end

function find(tbl, val)
    for _, el in ipairs(tbl) do
        if el == val then
            return true
        end
    end
    return false
end

function updatepackage(package) 
    local name = package[1]
    local version = package[2]
    local tag = name .. "-" .. version
    print("Updating package " .. tag)
    local assets = os.iorunv("gh", {"release", "view", tag, "--json", "assets"})
    local assets_json = assert(json.decode(assets).assets, "assets not found!")
    local manifestfile = path.join("packages", name:sub(1, 1), name, version, "manifest.txt")
    local cachefile = path.join("packages", name:sub(1, 1), name, version, "cache.json")
    local cache = os.exists(cachefile) and json.loadfile(cachefile) or {}
    assert(#assets_json, "assets are empty!")
    os.mkdir("artifacts")
    
    local manifest = os.isfile(manifestfile) and io.load(manifestfile) or {}
    local manifest_oldkey = get_manifestkey(manifest)
    for _, asset in ipairs(assets_json) do
        local buildid = path.basename(asset.name):gsub("-%w+$", "")
        local cachekey = path.basename(asset.name):match("-(%w+)$")
        if not find(cache, cachekey) then
            table.insert(cache, cachekey)
        end
        if not manifest[buildid] then
            http.download(asset.url, path.join("artifacts", asset.name))

            manifest[buildid] = {
                urls = asset.url,
                sha256 = hash.sha256(path.join("artifacts", asset.name))
            }

            if asset.name:find("-vc143-", 1, true) then
                manifest[buildid].toolset = "14.34.31933"
            end
            if asset.name:find("-vc142-", 1, true) then
                manifest[buildid].toolset = "14.29.30133"
            end
            if asset.name:find("-vc141-", 1, true) then
                manifest[buildid].toolset = "14.16.27023"
            end
        end
    end

    json.savefile(cachefile, cache)
    if get_manifestkey(manifest) == manifest_oldkey then
        print("manifest not changed!")
        return
    end
    io.save(manifestfile, manifest)
end

function main()
    local buildpackages = json.loadfile(path.join(os.scriptdir(), "..", "packages.json"))
    local trycount = 0
    while trycount < 3 do
        local ok = try
        {
            function ()
                os.exec("git reset --hard origin/main")
                os.exec("git pull origin main")

                for _, package in ipairs(buildpackages) do
                    updatepackage(package)
                end

                os.exec("git add -A")
                os.exec("git commit -a -m \"autoupdate by ci\" --allow-empty")
                os.exec("git push origin main")
                return true
            end,
            catch
            {
                function (errors)
                    if errors then
                        print(tostring(errors))
                    end
                    os.exec("git reset --hard origin/main")
                    os.exec("git pull origin main")
                end
            }
        }
        if ok then
            break
        end
        trycount = trycount + 1
    end
    assert(trycount < 3, "push manifest failed!")
end