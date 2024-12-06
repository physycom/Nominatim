-- Nominatim themepark theme.
--
-- The Nominatim theme creates a fixed set of import tables for use with
-- Nominatim. Creation and object processing are directly controlled by
-- the theme. Topics provide preset configurations. You should add exactly
-- one topic to your project.
--
-- The theme also exports a number of functions that can be used to configure
-- its behaviour. These may be directly called in the style file after
-- importing the theme:
--
--      local nominatim = themepark:init_theme('nominatim')
--      nominatim.set_main_tags{boundary = 'always'}
--
-- This allows to write your own configuration from scratch. You can also
-- use it to customize topics. In that case, first add the topic, then
-- change the configuration:
--
--      themepark:add_topic('nominatim/full')
--      local nominatim = themepark:init_theme('nominatim')
--      nominatim.ignore_tags{'amenity'}

local module = {}

local POST_DELETE = nil
local MAIN_KEYS = {admin_level = {'delete'}}
local PRE_FILTER = {prefix = {}, suffix = {}}
local NAMES = nil
local ADDRESS_TAGS = nil
local SAVE_EXTRA_MAINS = false
local POSTCODE_FALLBACK = true

-- This file can also be directly require'd instead of running it under
-- the themepark framework. In that case the first parameter is usually
-- the module name. Lets check for that, so that further down we can call
-- the low-level osm2pgsql functions instead of themepark functions.
local themepark = ...
if type(themepark) ~= 'table' then
    themepark = nil
end

-- tables required for taginfo
module.TAGINFO_MAIN = {keys = {}, delete_tags = {}}
module.TAGINFO_NAME_KEYS = {}
module.TAGINFO_ADDRESS_KEYS = {}


-- The single place table.
local place_table_definition = {
    name = "place",
    ids = { type = 'any', id_column = 'osm_id', type_column = 'osm_type' },
    columns = {
        { column = 'class', type = 'text', not_null = true },
        { column = 'type', type = 'text', not_null = true },
        { column = 'admin_level', type = 'smallint' },
        { column = 'name', type = 'hstore' },
        { column = 'address', type = 'hstore' },
        { column = 'extratags', type = 'hstore' },
        { column = 'geometry', type = 'geometry', projection = 'WGS84', not_null = true },
    },
    data_tablespace = os.getenv("NOMINATIM_TABLESPACE_PLACE_DATA"),
    index_tablespace = os.getenv("NOMINATIM_TABLESPACE_PLACE_INDEX"),
    indexes = {}
}

local insert_row

if themepark then
    themepark:add_table(place_table_definition)
    insert_row = function(columns)
        themepark:insert('place', columns, {}, {})
    end
else
    local place_table = osm2pgsql.define_table(place_table_definition)
    insert_row = function(columns)
        place_table:insert(columns)
    end
end

------------ Geometry functions for relations ---------------------

function module.relation_as_multipolygon(o)
    return o:as_multipolygon()
end

function module.relation_as_multiline(o)
    return o:as_multilinestring():line_merge()
end


module.RELATION_TYPES = {
    multipolygon = module.relation_as_multipolygon,
    boundary = module.relation_as_multipolygon,
    waterway = module.relation_as_multiline
}

--------- Built-in place transformation functions --------------------------

local PlaceTransform = {}

-- Special transform meanings which are interpreted elsewhere
PlaceTransform.fallback = 'fallback'
PlaceTransform.delete = 'delete'
PlaceTransform.extra = 'extra'

-- always: unconditionally use that place
function PlaceTransform.always(place)
    return place
end

-- never: unconditionally drop the place
function PlaceTransform.never()
    return nil
end

-- named: use the place if it has a fully-qualified name
function PlaceTransform.named(place)
    if place.has_name then
        return place
    end
end

-- named_with_key: use place if there is a name with the main key prefix
function PlaceTransform.named_with_key(place, k)
    local names = {}
    local prefix = k .. ':name'
    for namek, namev in pairs(place.intags) do
        if namek:sub(1, #prefix) == prefix
           and (#namek == #prefix
                or namek:sub(#prefix + 1, #prefix + 1) == ':') then
            names[namek:sub(#k + 2)] = namev
        end
    end

    if next(names) ~= nil then
        return place:clone{names=names}
    end
end

----------------- other helper functions -----------------------------

local function lookup_prefilter_classification(k, v)
    -- full matches
    local desc = MAIN_KEYS[k]
    local fullmatch = desc and (desc[v] or desc[1])
    if fullmatch ~= nil then
        return fullmatch
    end
    -- suffixes
    for slen, slist in pairs(PRE_FILTER.suffix) do
        if #k >= slen then
            local group = slist[k:sub(-slen)]
            if group ~= nil then
                return group
            end
        end
    end
    -- prefixes
    for slen, slist in pairs(PRE_FILTER.prefix) do
        if #k >= slen then
            local group = slist[k:sub(1, slen)]
            if group ~= nil then
                return group
            end
        end
    end
end


local function merge_filters_into_main(group, keys, tags)
    if keys ~= nil then
        for _, key in pairs(keys) do
            -- ignore suffix and prefix matches
            if key:sub(1, 1) ~= '*' and key:sub(#key, #key) ~= '*' then
                if MAIN_KEYS[key] == nil then
                    MAIN_KEYS[key] = {}
                end
                MAIN_KEYS[key][1] = group
            end
        end
    end

    if tags ~= nil then
        for key, values in pairs(tags) do
            if MAIN_KEYS[key] == nil then
                MAIN_KEYS[key] = {}
            end
            for _, v in pairs(values) do
                MAIN_KEYS[key][v] = group
            end
        end
    end
end


local function remove_group_from_main(group)
    for key, values in pairs(MAIN_KEYS) do
        for _, ttype in pairs(values) do
            if ttype == group then
                values[ttype] = nil
            end
        end
        if next(values) == nil then
            MAIN_KEYS[key] = nil
        end
    end
end


local function add_pre_filter(data)
    for group, keys in pairs(data) do
        for _, key in pairs(keys) do
            local klen = #key - 1
            if key:sub(1, 1) == '*' then
                if klen > 0 then
                    if PRE_FILTER.suffix[klen] == nil then
                        PRE_FILTER.suffix[klen] = {}
                    end
                    PRE_FILTER.suffix[klen][key:sub(2)] = group
                end
            elseif key:sub(#key, #key) == '*' then
                if PRE_FILTER.prefix[klen] == nil then
                    PRE_FILTER.prefix[klen] = {}
                end
                PRE_FILTER.prefix[klen][key:sub(1, klen)] = group
            end
        end
    end
end

------------- Place class ------------------------------------------

local Place = {}
Place.__index = Place

function Place.new(object, geom_func)
    local self = setmetatable({}, Place)
    self.object = object
    self.geom_func = geom_func

    self.admin_level = tonumber(self.object.tags.admin_level or 15) or 15
    if self.admin_level == nil
       or self.admin_level <= 0 or self.admin_level > 15
       or math.floor(self.admin_level) ~= self.admin_level then
        self.admin_level = 15
    end

    self.num_entries = 0
    self.has_name = false
    self.names = {}
    self.address = {}
    self.extratags = {}

    self.intags = {}

    local has_main_tags = false
    for k, v in pairs(self.object.tags) do
        local group = lookup_prefilter_classification(k, v)
        if group == 'extra' then
            self.extratags[k] = v
        elseif group ~= 'delete' then
            self.intags[k] = v
            if group ~= nil then
                has_main_tags = true
            end
        end
    end

    if not has_main_tags then
        -- no interesting tags, don't bother processing
        self.intags = {}
    end

    return self
end

function Place:clean(data)
    for k, v in pairs(self.intags) do
        if data.delete ~= nil and data.delete(k, v) then
            self.intags[k] = nil
        elseif data.extra ~= nil and data.extra(k, v) then
            self.extratags[k] = v
            self.intags[k] = nil
        end
    end
end

function Place:delete(data)
    if data.match ~= nil then
        for k, v in pairs(self.intags) do
            if data.match(k, v) then
                self.intags[k] = nil
            end
        end
    end
end

function Place:grab_extratags(data)
    local count = 0

    if data.match ~= nil then
        for k, v in pairs(self.intags) do
            if data.match(k, v) then
                self.intags[k] = nil
                self.extratags[k] = v
                count = count + 1
            end
        end
    end

    return count
end

local function strip_address_prefix(k)
    if k:sub(1, 5) == 'addr:' then
        return k:sub(6)
    end

    if k:sub(1, 6) == 'is_in:' then
        return k:sub(7)
    end

    return k
end


function Place:grab_address_parts(data)
    local count = 0

    if data.groups ~= nil then
        for k, v in pairs(self.intags) do
            local atype = data.groups(k, v)

            if atype ~= nil then
                if atype == 'main' then
                    self.has_name = true
                    self.address[strip_address_prefix(k)] = v
                    count = count + 1
                elseif atype == 'extra' then
                    self.address[strip_address_prefix(k)] = v
                else
                    self.address[atype] = v
                end
                self.intags[k] = nil
            end
        end
    end

    return count
end


function Place:grab_name_parts(data)
    local fallback = nil

    if data.groups ~= nil then
        for k, v in pairs(self.intags) do
            local atype = data.groups(k, v)

            if atype ~= nil then
                self.names[k] = v
                self.intags[k] = nil
                if atype == 'main' then
                    self.has_name = true
                elseif atype == 'house' then
                    self.has_name = true
                    fallback = {'place', 'house', PlaceTransform.always}
                end
            end
        end
    end

    return fallback
end


function Place:write_place(k, v, mfunc, save_extra_mains)
    v = v or self.intags[k]
    if v == nil then
        return 0
    end

    local place = mfunc(self, k, v)
    if place then
        local res = place:write_row(k, v, save_extra_mains)
        self.num_entries = self.num_entries + res
        return res
    end

    return 0
end

function Place:write_row(k, v, save_extra_mains)
    if self.geometry == nil then
        self.geometry = self.geom_func(self.object)
    end
    if self.geometry:is_null() then
        return 0
    end

    if save_extra_mains ~= nil then
        for extra_k, extra_v in pairs(self.intags) do
            if extra_k ~= k and save_extra_mains(extra_k, extra_v) then
                self.extratags[extra_k] = extra_v
            end
        end
    end

    insert_row{
        class = k,
        type = v,
        admin_level = self.admin_level,
        name = next(self.names) and self.names,
        address = next(self.address) and self.address,
        extratags = next(self.extratags) and self.extratags,
        geometry = self.geometry
    }

    if save_extra_mains then
        for tk, tv in pairs(self.intags) do
            if save_extra_mains(tk, tv) then
                self.extratags[tk] = nil
            end
        end
    end

    return 1
end


function Place:clone(data)
    local cp = setmetatable({}, Place)
    cp.object = self.object
    cp.geometry = data.geometry or self.geometry
    cp.geom_func = self.geom_func
    cp.intags = data.intags or self.intags
    cp.admin_level = data.admin_level or self.admin_level
    cp.names = data.names or self.names
    cp.address = data.address or self.address
    cp.extratags = data.extratags or self.extratags

    return cp
end


function module.tag_match(data)
    if data == nil or next(data) == nil then
        return nil
    end

    local fullmatches = {}
    local key_prefixes = {}
    local key_suffixes = {}

    if data.keys ~= nil then
        for _, key in pairs(data.keys) do
            if key:sub(1, 1) == '*' then
                if #key > 1 then
                    if key_suffixes[#key - 1] == nil then
                        key_suffixes[#key - 1] = {}
                    end
                    key_suffixes[#key - 1][key:sub(2)] = true
                end
            elseif key:sub(#key, #key) == '*' then
                if key_prefixes[#key - 1] == nil then
                    key_prefixes[#key - 1] = {}
                end
                key_prefixes[#key - 1][key:sub(1, #key - 1)] = true
            else
                fullmatches[key] = true
            end
        end
    end

    if data.tags ~= nil then
        for k, vlist in pairs(data.tags) do
            if fullmatches[k] == nil then
                fullmatches[k] = {}
                for _, v in pairs(vlist) do
                    fullmatches[k][v] = true
                end
            end
        end
    end

    return function (k, v)
        if fullmatches[k] ~= nil and (fullmatches[k] == true or fullmatches[k][v] ~= nil) then
            return true
        end

        for slen, slist in pairs(key_suffixes) do
            if #k >= slen and slist[k:sub(-slen)] ~= nil then
                return true
            end
        end

        for slen, slist in pairs(key_prefixes) do
            if #k >= slen and slist[k:sub(1, slen)] ~= nil then
                return true
            end
        end

        return false
    end
end


function module.tag_group(data)
    if data == nil or next(data) == nil then
        return nil
    end

    local fullmatches = {}
    local key_prefixes = {}
    local key_suffixes = {}

    for group, tags in pairs(data) do
        for _, key in pairs(tags) do
            if key:sub(1, 1) == '*' then
                if #key > 1 then
                    if key_suffixes[#key - 1] == nil then
                        key_suffixes[#key - 1] = {}
                    end
                    key_suffixes[#key - 1][key:sub(2)] = group
                end
            elseif key:sub(#key, #key) == '*' then
                if key_prefixes[#key - 1] == nil then
                    key_prefixes[#key - 1] = {}
                end
                key_prefixes[#key - 1][key:sub(1, #key - 1)] = group
            else
                fullmatches[key] = group
            end
        end
    end

    return function (k, v)
        local val = fullmatches[k]
        if val ~= nil then
            return val
        end

        for slen, slist in pairs(key_suffixes) do
            if #k >= slen then
                val = slist[k:sub(-slen)]
                if val ~= nil then
                    return val
                end
            end
        end

        for slen, slist in pairs(key_prefixes) do
            if #k >= slen then
                val = slist[k:sub(1, slen)]
                if val ~= nil then
                    return val
                end
            end
        end
    end
end

-- Returns prefix part of the keys, and reject suffix matching keys
local function process_key(key)
    if key:sub(1, 1) == '*' then
        return nil
    end
    if key:sub(#key, #key) == '*' then
        return key:sub(1, #key - 2)
    end
    return key
end

-- Process functions for all data types
function module.process_node(object)

    local function geom_func(o)
        return o:as_point()
    end

    module.process_tags(Place.new(object, geom_func))
end

function module.process_way(object)

    local function geom_func(o)
        local geom = o:as_polygon()

        if geom:is_null() then
            geom = o:as_linestring()
        end

        return geom
    end

    module.process_tags(Place.new(object, geom_func))
end

function module.process_relation(object)
    local geom_func = module.RELATION_TYPES[object.tags.type]

    if geom_func ~= nil then
        module.process_tags(Place.new(object, geom_func))
    end
end

-- The process functions are used by default by osm2pgsql.
if themepark then
    themepark:add_proc('node', module.process_node)
    themepark:add_proc('way', module.process_way)
    themepark:add_proc('relation', module.process_relation)
else
    osm2pgsql.process_node = module.process_node
    osm2pgsql.process_way = module.process_way
    osm2pgsql.process_relation = module.process_relation
end

function module.process_tags(o)
    if next(o.intags) == nil then
        return  -- shortcut when pre-filtering has removed all tags
    end

    -- Exception for boundary/place double tagging
    if o.intags.boundary == 'administrative' then
        o:grab_extratags{match = function (k, v)
            return k == 'place' and v:sub(1,3) ~= 'isl'
        end}
    end

    -- name keys
    local fallback = o:grab_name_parts{groups=NAMES}

    -- address keys
    if o:grab_address_parts{groups=ADDRESS_TAGS} > 0 and fallback == nil then
        fallback = {'place', 'house', PlaceTransform.always}
    end
    if o.address.country ~= nil and #o.address.country ~= 2 then
        o.address['country'] = nil
    end
    if POSTCODE_FALLBACK and fallback == nil and o.address.postcode ~= nil then
        fallback = {'place', 'postcode', PlaceTransform.always}
    end

    if o.address.interpolation ~= nil then
        o:write_place('place', 'houses', PlaceTransform.always, SAVE_EXTRA_MAINS)
        return
    end

    o:clean{delete = POST_DELETE}

    -- collect main keys
    for k, v in pairs(o.intags) do
        local ktable = MAIN_KEYS[k]
        if ktable then
            local ktype = ktable[v] or ktable[1]
            if type(ktype) == 'function' then
                o:write_place(k, v, ktype, SAVE_EXTRA_MAINS)
            elseif ktype == 'fallback' and o.has_name then
                fallback = {k, v, PlaceTransform.named}
            end
        end
    end

    if fallback ~= nil and o.num_entries == 0 then
        o:write_place(fallback[1], fallback[2], fallback[3], SAVE_EXTRA_MAINS)
    end
end

--------- Convenience functions for simple style configuration -----------------

function module.set_prefilters(data)
    remove_group_from_main('delete')
    merge_filters_into_main('delete', data.delete_keys, data.delete_tags)

    remove_group_from_main('extra')
    merge_filters_into_main('extra', data.extra_keys, data.extra_tags)

    PRE_FILTER = {prefix = {}, suffix = {}}
    add_pre_filter{delete = data.delete_keys, extra = data.extra_keys}
end


function module.ignore_tags(data)
    merge_filters_into_main('delete', data)
    add_pre_filter{delete = data}
end


function module.add_for_extratags(data)
    merge_filters_into_main('extra', data)
    add_pre_filter{extra = data}
end


function module.set_main_tags(data)
    for key, values in pairs(MAIN_KEYS) do
        for _, ttype in pairs(values) do
            if ttype == 'fallback' or type(ttype) == 'function' then
                values[ttype] = nil
            end
        end
        if next(values) == nil then
            MAIN_KEYS[key] = nil
        end
    end
    module.add_main_tags(data)
end


function module.add_main_tags(data)
    for k, v in pairs(data) do
        if MAIN_KEYS[k] == nil then
            MAIN_KEYS[k] = {}
        end
        if type(v) == 'function' then
            MAIN_KEYS[k][1] = v
        elseif type(v) == 'string' then
            MAIN_KEYS[k][1] = PlaceTransform[v]
        elseif type(v) == 'table' then
            for subk, subv in pairs(v) do
                if type(subv) == 'function' then
                    MAIN_KEYS[k][subk] = subv
                else
                    MAIN_KEYS[k][subk] = PlaceTransform[subv]
                end
            end
        end
    end
end


function module.set_name_tags(data)
    NAMES = module.tag_group(data)

    for _, lst in pairs(data) do
        for _, k in ipairs(lst) do
            local key = process_key(k)
            if key ~= nil then
                module.TAGINFO_NAME_KEYS[key] = true
            end
        end
    end
    remove_group_from_main('fallback:name')
    merge_filters_into_main('fallback:name', data.house)
end


function module.set_address_tags(data)
    if data.postcode_fallback ~= nil then
        POSTCODE_FALLBACK = data.postcode_fallback
        data.postcode_fallback = nil
    end
    ADDRESS_TAGS = module.tag_group(data)

    for _, lst in pairs(data) do
        if lst ~= nil then
            for _, k in ipairs(lst) do
                local key = process_key(k)
                if key ~= nil then
                    module.TAGINFO_ADDRESS_KEYS[key] = true
                end
            end
        end
    end

    remove_group_from_main('fallback:address')
    remove_group_from_main('fallback:postcode')
    merge_filters_into_main('fallback:address', data.main)
    if POSTCODE_FALLBACK then
        merge_filters_into_main('fallback:postcode', data.postcode)
    end
    merge_filters_into_main('fallback:address', data.interpolation)
end


function module.set_unused_handling(data)
    if data.extra_keys == nil and data.extra_tags == nil then
        POST_DELETE = module.tag_match{keys = data.delete_keys, tags = data.delete_tags}
        SAVE_EXTRA_MAINS = function() return true end
    elseif data.delete_keys == nil and data.delete_tags == nil then
        POST_DELETE = nil
        SAVE_EXTRA_MAINS = module.tag_match{keys = data.extra_keys, tags = data.extra_tags}
    else
        error("unused handler can have only 'extra_keys' or 'delete_keys' set.")
    end
end

function module.set_relation_types(data)
    module.RELATION_TYPES = {}
    for k, v in data do
        if v == 'multipolygon' then
            module.RELATION_TYPES[k] = module.relation_as_multipolygon
        elseif v == 'multiline' then
            module.RELATION_TYPES[k] = module.relation_as_multiline
        end
    end
end

return module
