//! Weather service for perihelionbar-shell: the data model, Open-Meteo
//! request/response handling, location resolution and refresh schedule.
//!
//! Shared by both binaries: the desktop card (perihelionbar-shell widgets.zig
//! WeatherWidget) and the top-bar indicator (perihelionbar main.zig
//! BarWeather). No rendering, no font, no fds of its own: each host owns its
//! curl child and its drawing; this file decides *what* to fetch and *when*,
//! and turns the answer into a `Weather` snapshot.
//!
//! The two processes stay in step through the same shell.json keys
//! (ShellJsonKeys) and a small cache file (defaultCachePath): whoever
//! fetches writes the answer there, and the other adopts it instead of
//! fetching, so between them they make one set of Open-Meteo requests.
//!
//! Tests: `zig build test-weather` in perihelionbar/, or
//! `zig test -lc src/weather.zig` (libc only for time/getenv/file I/O).
//!
//! The data contract, refresh cadence and retry policy:
//!   - refresh every 15 min (+/- 7.5 s jitter, never under 60 s)
//!   - forecast requests at least 30 s apart
//!   - up to 3 quick attempts 30 s apart, then exponential backoff
//!     60 s, 120 s, 240 s, capped at 300 s
//!   - a failed refresh keeps the last good reading on screen (marked stale)
//!
//! Location, in priority order:
//!   1. manual latitude/longitude (shell.json weather_latitude/longitude,
//!      or "32.59,-96.86" written as the place)
//!   2. a city name or postal code, geocoded once through Open-Meteo.
//!      "City, ST" narrows to that US state, "City, FR" to that country,
//!      "City, Region" prefers a result in that region or country.
//!   3. IP geolocation (weather_auto_location, on by default)
//!
//! Units: °C or °F as configured, or "auto" (the default): °F for places
//! in the United States (and the few other countries that use it), °C
//! everywhere else, decided from the place's country — or, for bare
//! coordinates, from the forecast's time zone.

const std = @import("std");
const posix = std.posix;

/// libc bits the shared cache needs (both binaries link libc anyway; the
/// rest of the tree binds getenv/time by hand the same way).
const libc = struct {
    extern "c" fn time(t: ?*i64) i64;
    extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
};

fn wallSeconds() i64 {
    return libc.time(null);
}

pub const FORECAST_DAYS: usize = 7;

pub const DEFAULT_REFRESH_MS: i64 = 900_000;
pub const MIN_REFRESH_MS: i64 = 60_000;
pub const MIN_FETCH_INTERVAL_MS: i64 = 30_000;
pub const RETRY_DELAY_MS: i64 = 30_000;
pub const MAX_RETRIES: u8 = 3;
pub const BACKOFF_BASE_MS: i64 = 60_000;
pub const BACKOFF_CAP_MS: i64 = 300_000;
pub const JITTER_MS: i64 = 7_500;

pub const FORECAST_URL = "https://api.open-meteo.com/v1/forecast";
pub const GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search";
/// HTTPS, no key, ~1k lookups/day free. ip-api.com's answer shape is
/// parsed too, so weather_ip_url can point there instead.
pub const DEFAULT_IP_URL = "https://ipapi.co/json/";

const CURRENT_FIELDS = "temperature_2m,relative_humidity_2m,apparent_temperature,is_day," ++
    "precipitation,weather_code,surface_pressure,wind_speed_10m";
// uv_index_max is requested too (rather than hard-coding uv = 0): same
// call, a few more bytes, and the uv field is real.
const DAILY_FIELDS = "sunrise,sunset,temperature_2m_max,temperature_2m_min,weather_code," ++
    "precipitation_probability_max,uv_index_max";

// --- small fixed-capacity text ---------------------------------------------

/// Inline string with a fixed capacity: the snapshot is copied around by
/// value and must never point into a fetch buffer that gets reused.
pub fn BoundedText(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        /// Copies `s`, truncated on a UTF-8 boundary if it doesn't fit.
        pub fn set(self: *Self, s: []const u8) void {
            var n: usize = @min(s.len, N);
            while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const Name = BoundedText(48);
const Hhmm = BoundedText(5);

// --- units -----------------------------------------------------------------

pub const Units = enum {
    celsius,
    fahrenheit,

    /// "C"/"F" (shell.json weather_units); also accepts the spelled-out
    /// and metric/imperial forms people tend to type.
    pub fn parse(s: []const u8) ?Units {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(s, "c") or eq(s, "celsius") or eq(s, "metric")) return .celsius;
        if (eq(s, "f") or eq(s, "fahrenheit") or eq(s, "imperial")) return .fahrenheit;
        return null;
    }

    pub fn tag(self: Units) []const u8 {
        return switch (self) {
            .celsius => "C",
            .fahrenheit => "F",
        };
    }

    pub fn toggled(self: Units) Units {
        return switch (self) {
            .celsius => .fahrenheit,
            .fahrenheit => .celsius,
        };
    }
};

pub fn cToF(c: f32) f32 {
    return c * 9.0 / 5.0 + 32.0;
}

/// Rounds for display; -0.4 shows as 0, not -0.
pub fn roundi(v: f32) i32 {
    const r = @round(v);
    if (r > 999.0 or r < -999.0) return 0; // garbage guard, never on real data
    return @intFromFloat(r);
}

// --- data model ------------------------------------------------------------

pub const ForecastDay = struct {
    /// "YYYY-MM-DD" in the location's own timezone (timezone=auto).
    date: BoundedText(10) = .{},
    /// "Mon".."Sun"; the widget shows "Today" for index 0.
    day_name: BoundedText(3) = .{},
    max_c: f32 = 0,
    min_c: f32 = 0,
    w_code: u32 = 0,
    precip_prob: u32 = 0,
    uv_max: f32 = 0,
    sunrise: Hhmm = .{},
    sunset: Hhmm = .{},

    pub fn max(self: *const ForecastDay, u: Units) f32 {
        return if (u == .fahrenheit) cToF(self.max_c) else self.max_c;
    }

    pub fn min(self: *const ForecastDay, u: Units) f32 {
        return if (u == .fahrenheit) cToF(self.min_c) else self.min_c;
    }
};

pub const SunEvent = struct { sunrise: bool, at: []const u8 };

/// One weather snapshot (snake_case fields; `wind` keeps the API's own
/// "12 km/h").
pub const Weather = struct {
    available: bool = false,
    loading: bool = true,
    /// A refresh failed after this reading was taken (it is still shown).
    stale: bool = false,
    temp_c: f32 = 0,
    temp_f: f32 = 0,
    feels_like_c: f32 = 0,
    feels_like_f: f32 = 0,
    city: Name = .{},
    country: Name = .{},
    w_code: u32 = 0,
    humidity: u32 = 0,
    wind: BoundedText(16) = .{},
    wind_kmh: f32 = 0,
    sunrise: Hhmm = .{},
    sunset: Hhmm = .{},
    uv: f32 = 0,
    pressure: f32 = 0,
    precip_mm: f32 = 0,
    precip_prob: u32 = 0,
    is_day: bool = true,
    /// Local "HH:MM" the reading is for (Open-Meteo's current.time).
    observed: Hhmm = .{},
    /// IANA time zone of the place (Open-Meteo's timezone=auto answer).
    timezone: BoundedText(48) = .{},
    forecast: [FORECAST_DAYS]ForecastDay = [_]ForecastDay{.{}} ** FORECAST_DAYS,
    forecast_len: usize = 0,

    pub fn temp(self: *const Weather, u: Units) f32 {
        return if (u == .fahrenheit) self.temp_f else self.temp_c;
    }

    pub fn feelsLike(self: *const Weather, u: Units) f32 {
        return if (u == .fahrenheit) self.feels_like_f else self.feels_like_c;
    }

    pub fn days(self: *const Weather) []const ForecastDay {
        return self.forecast[0..self.forecast_len];
    }

    /// The next sunset (by day) or sunrise (by night) — tomorrow's sunrise
    /// once the reading is past today's sunset. Null without daily data.
    pub fn nextSunEvent(self: *const Weather) ?SunEvent {
        if (self.is_day) {
            if (self.sunset.len == 0) return null;
            return .{ .sunrise = false, .at = self.sunset.slice() };
        }
        const after_sunset = self.observed.len == 5 and self.sunset.len == 5 and
            std.mem.order(u8, self.observed.slice(), self.sunset.slice()) != .lt;
        if (after_sunset and self.forecast_len > 1 and self.forecast[1].sunrise.len > 0) {
            return .{ .sunrise = true, .at = self.forecast[1].sunrise.slice() };
        }
        if (self.sunrise.len == 0) return null;
        return .{ .sunrise = true, .at = self.sunrise.slice() };
    }

    /// Wind in the display unit: km/h for Celsius, mph for Fahrenheit.
    pub fn windText(self: *const Weather, u: Units, out: []u8) []const u8 {
        return switch (u) {
            .celsius => std.fmt.bufPrint(out, "{d} km/h", .{roundi(self.wind_kmh)}) catch "",
            .fahrenheit => std.fmt.bufPrint(out, "{d} mph", .{roundi(self.wind_kmh * 0.621371)}) catch "",
        };
    }
};

// --- WMO weather codes -------------------------------------------------------

/// Condition families: what the icon, tint and card animation key on.
pub const Kind = enum {
    clear,
    partly_cloudy,
    overcast,
    fog,
    drizzle,
    freezing,
    rain,
    showers,
    snow,
    snow_showers,
    thunderstorm,
    unknown,
};

pub fn kindFor(code: u32) Kind {
    return switch (code) {
        0, 1 => .clear,
        2 => .partly_cloudy,
        3 => .overcast,
        45, 48 => .fog,
        51, 53, 55 => .drizzle,
        56, 57, 66, 67 => .freezing,
        61, 63, 65 => .rain,
        80, 81, 82 => .showers,
        71, 73, 75, 77 => .snow,
        85, 86 => .snow_showers,
        95, 96, 99 => .thunderstorm,
        else => .unknown,
    };
}

/// Human-readable condition (WMO code table; 66/67 and 80-82 say
/// what they are — freezing rain and showers — instead of plain "rain").
pub fn conditionText(code: u32) []const u8 {
    return switch (code) {
        0, 1 => "Clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45, 48 => "Fog",
        51, 53, 55 => "Drizzle",
        56, 57 => "Freezing drizzle",
        61 => "Light rain",
        63 => "Rain",
        65 => "Heavy rain",
        66 => "Light freezing rain",
        67 => "Freezing rain",
        71 => "Light snow",
        73 => "Snow",
        75 => "Heavy snow",
        77 => "Snow grains",
        80 => "Light showers",
        81 => "Showers",
        82 => "Heavy showers",
        85 => "Light snow showers",
        86 => "Heavy snow showers",
        95 => "Thunderstorm",
        96, 99 => "Thunderstorm with hail",
        else => "Unknown",
    };
}

/// Nerd Font weather-icons codepoint (U+E300 block), day/night aware.
/// Every value checked against nerd-fonts glyphnames.json.
pub fn iconFor(code: u32, is_day: bool) u32 {
    return switch (kindFor(code)) {
        .clear => if (is_day) 0xE30D else 0xE32B, // day_sunny / night_clear
        .partly_cloudy => if (is_day) 0xE302 else 0xE379, // day_cloudy / night_alt_partly_cloudy
        .overcast => 0xE312, // cloudy
        .fog => if (is_day) 0xE303 else 0xE346, // day_fog / night_fog
        .drizzle => 0xE31B, // sprinkle
        .freezing => 0xE3AD, // sleet
        .rain => 0xE318, // rain
        .showers => if (is_day) 0xE309 else 0xE326, // day_showers / night_alt_showers
        .snow => 0xE31A, // snow
        .snow_showers => if (is_day) 0xE30A else 0xE327, // day_snow / night_alt_snow
        .thunderstorm => if (code == 95) 0xE31D else 0xE31C, // thunderstorm / storm_showers
        .unknown => 0xE374, // na
    };
}

/// Semantic condition tint (0xAARRGGBB) — the same palette the shell's
/// card already used, plus a lavender for clear nights.
pub fn tintFor(code: u32, is_day: bool) u32 {
    return switch (kindFor(code)) {
        .clear => if (is_day) 0xFFFFD60A else 0xFFB7BDF8,
        .partly_cloudy => if (is_day) 0xFFFFB340 else 0xFFA9B4E8,
        .overcast => 0xFF9AA7B8,
        .fog => 0xFF8E9AAF,
        .drizzle, .rain, .showers => 0xFF4AA8FF,
        .freezing => 0xFF8CC8FF,
        .snow, .snow_showers => 0xFFA8E6FF,
        .thunderstorm => 0xFFB48CFF,
        .unknown => 0,
    };
}

// --- Open-Meteo / geolocation answer shapes -----------------------------------
// Every field optional and nullable: Open-Meteo sends null inside daily
// arrays when a model has no value, and a missing key must degrade, not fail.

const OmCurrent = struct {
    time: ?[]const u8 = null,
    temperature_2m: ?f64 = null,
    relative_humidity_2m: ?f64 = null,
    apparent_temperature: ?f64 = null,
    is_day: ?f64 = null,
    precipitation: ?f64 = null,
    weather_code: ?f64 = null,
    surface_pressure: ?f64 = null,
    wind_speed_10m: ?f64 = null,
};

const OmCurrentUnits = struct {
    wind_speed_10m: ?[]const u8 = null,
};

const OmDaily = struct {
    time: ?[]const ?[]const u8 = null,
    sunrise: ?[]const ?[]const u8 = null,
    sunset: ?[]const ?[]const u8 = null,
    temperature_2m_max: ?[]const ?f64 = null,
    temperature_2m_min: ?[]const ?f64 = null,
    weather_code: ?[]const ?f64 = null,
    precipitation_probability_max: ?[]const ?f64 = null,
    uv_index_max: ?[]const ?f64 = null,
};

const OmResponse = struct {
    timezone: ?[]const u8 = null,
    current: ?OmCurrent = null,
    current_units: ?OmCurrentUnits = null,
    daily: ?OmDaily = null,
};

/// ipapi.co and ip-api.com, merged: whichever keys are present win.
const IpResponse = struct {
    // ipapi.co
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    country_name: ?[]const u8 = null,
    @"error": ?bool = null,
    // ip-api.com
    lat: ?f64 = null,
    lon: ?f64 = null,
    status: ?[]const u8 = null,
    // both (ipapi.co's "country" is the ISO code, ip-api's the name)
    city: ?[]const u8 = null,
    country: ?[]const u8 = null,
    // ISO codes: ipapi.co / Fedora's geoip, ip-api
    country_code: ?[]const u8 = null,
    countryCode: ?[]const u8 = null,
};

const GeoResult = struct {
    name: ?[]const u8 = null,
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    country: ?[]const u8 = null,
    country_code: ?[]const u8 = null,
    /// State / province / region.
    admin1: ?[]const u8 = null,
};

const GeoResponse = struct {
    results: ?[]const GeoResult = null,
};

fn at(comptime T: type, arr: ?[]const ?T, i: usize) ?T {
    const a = arr orelse return null;
    if (i >= a.len) return null;
    return a[i];
}

fn validCoords(lat: f64, lon: f64) bool {
    return !std.math.isNan(lat) and !std.math.isNan(lon) and
        lat >= -90.0 and lat <= 90.0 and lon >= -180.0 and lon <= 180.0;
}

/// "2026-11-18T06:45" → "06:45" (already local: timezone=auto).
fn isoHhmm(iso: ?[]const u8) []const u8 {
    const s = iso orelse return "";
    if (s.len < 16 or s[10] != 'T') return "";
    return s[11..16];
}

const WEEKDAYS = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };

/// Weekday of "YYYY-MM-DD" (Hinnant's days_from_civil; 1970-01-01 = Thu).
fn weekdayName(date: []const u8) []const u8 {
    if (date.len < 10 or date[4] != '-' or date[7] != '-') return "";
    const y = std.fmt.parseInt(i64, date[0..4], 10) catch return "";
    const m = std.fmt.parseInt(i64, date[5..7], 10) catch return "";
    const d = std.fmt.parseInt(i64, date[8..10], 10) catch return "";
    if (m < 1 or m > 12 or d < 1 or d > 31) return "";
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return WEEKDAYS[@intCast(@mod(days + 4, 7))];
}

/// "America/Argentina/Buenos_Aires" → "Buenos Aires": a free place name
/// for manual coordinates without a weather_city label, with no extra
/// reverse-geocoding request.
fn cityFromTimezone(tz: []const u8, out: *Name) void {
    const tail = if (std.mem.lastIndexOfScalar(u8, tz, '/')) |i| tz[i + 1 ..] else tz;
    out.set(tail);
    for (out.buf[0..out.len]) |*ch| {
        if (ch.* == '_') ch.* = ' ';
    }
}

/// RFC 3986 unreserved characters pass, everything else is %XX.
fn percentEncode(src: []const u8, out: []u8) ?[]const u8 {
    const hex = "0123456789ABCDEF";
    var n: usize = 0;
    for (src) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
        if (plain) {
            if (n + 1 > out.len) return null;
            out[n] = ch;
            n += 1;
        } else {
            if (n + 3 > out.len) return null;
            out[n] = '%';
            out[n + 1] = hex[ch >> 4];
            out[n + 2] = hex[ch & 0x0F];
            n += 3;
        }
    }
    return out[0..n];
}

/// Parses an Open-Meteo /v1/forecast answer into `out`, taking place names
/// from `city`/`country` (empty city → derived from the answer's timezone).
/// False when the answer isn't a usable forecast (error JSON, truncated
/// body, missing current block).
pub fn parseForecast(body: []const u8, city: []const u8, country: []const u8, out: *Weather) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = std.json.parseFromSliceLeaky(OmResponse, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    const cur = r.current orelse return false;
    const daily = r.daily orelse return false;
    const t = cur.temperature_2m orelse return false;

    var w = Weather{ .available = true, .loading = false };
    w.temp_c = @floatCast(t);
    w.temp_f = cToF(w.temp_c);
    w.feels_like_c = @floatCast(cur.apparent_temperature orelse t);
    w.feels_like_f = cToF(w.feels_like_c);
    w.w_code = @intFromFloat(std.math.clamp(cur.weather_code orelse 0, 0, 99));
    w.humidity = @intFromFloat(std.math.clamp(@round(cur.relative_humidity_2m orelse 0), 0, 100));
    w.wind_kmh = @floatCast(@max(cur.wind_speed_10m orelse 0, 0));
    const wind_unit = if (r.current_units) |u| (u.wind_speed_10m orelse "km/h") else "km/h";
    var wind_buf: [24]u8 = undefined;
    w.wind.set(std.fmt.bufPrint(&wind_buf, "{d} {s}", .{ roundi(w.wind_kmh), wind_unit }) catch "");
    w.pressure = @floatCast(cur.surface_pressure orelse 0);
    w.precip_mm = @floatCast(cur.precipitation orelse 0);
    w.is_day = (cur.is_day orelse 1) != 0;
    w.observed.set(isoHhmm(cur.time));

    if (city.len > 0) {
        w.city.set(city);
    } else if (r.timezone) |tz| {
        cityFromTimezone(tz, &w.city);
    }
    w.country.set(country);
    w.timezone.set(r.timezone orelse "");

    const n_days = if (daily.time) |ts| @min(ts.len, FORECAST_DAYS) else 0;
    for (0..n_days) |i| {
        const d = &w.forecast[i];
        d.* = .{};
        const date = at([]const u8, daily.time, i) orelse "";
        d.date.set(date);
        d.day_name.set(weekdayName(date));
        d.max_c = @floatCast(at(f64, daily.temperature_2m_max, i) orelse 0);
        d.min_c = @floatCast(at(f64, daily.temperature_2m_min, i) orelse 0);
        d.w_code = @intFromFloat(std.math.clamp(at(f64, daily.weather_code, i) orelse 0, 0, 99));
        d.precip_prob = @intFromFloat(std.math.clamp(@round(at(f64, daily.precipitation_probability_max, i) orelse 0), 0, 100));
        d.uv_max = @floatCast(@max(at(f64, daily.uv_index_max, i) orelse 0, 0));
        d.sunrise.set(isoHhmm(at([]const u8, daily.sunrise, i)));
        d.sunset.set(isoHhmm(at([]const u8, daily.sunset, i)));
    }
    w.forecast_len = n_days;
    if (n_days > 0) {
        w.sunrise = w.forecast[0].sunrise;
        w.sunset = w.forecast[0].sunset;
        w.uv = w.forecast[0].uv_max;
        w.precip_prob = w.forecast[0].precip_prob;
    }
    out.* = w;
    return true;
}

pub const Place = struct {
    lat: f64 = 0,
    lon: f64 = 0,
    city: Name = .{},
    country: Name = .{},
};

pub fn parseIpLocation(body: []const u8) ?Place {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = std.json.parseFromSliceLeaky(IpResponse, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    if (r.@"error" orelse false) return null;
    if (r.status) |s| {
        if (!std.mem.eql(u8, s, "success")) return null;
    }
    const lat = r.latitude orelse r.lat orelse return null;
    const lon = r.longitude orelse r.lon orelse return null;
    if (!validCoords(lat, lon)) return null;
    var p = Place{ .lat = lat, .lon = lon };
    p.city.set(r.city orelse "");
    p.country.set(r.country_name orelse r.country orelse r.country_code orelse r.countryCode orelse "");
    return p;
}

pub const GeocodeResult = union(enum) {
    found: Place,
    /// Valid answer, no match: retrying won't help.
    not_found,
    /// Network/parse failure: worth retrying.
    failed,
};

/// `prefer` (a region or country name, may be empty) picks the first result
/// in that region or country; otherwise the best match wins.
pub fn parseGeocode(body: []const u8, prefer: []const u8) GeocodeResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const r = std.json.parseFromSliceLeaky(GeoResponse, arena.allocator(), body, .{
        .ignore_unknown_fields = true,
    }) catch return .failed;
    const results = r.results orelse return .not_found;
    if (results.len == 0) return .not_found;
    var g = results[0];
    if (prefer.len > 0) {
        for (results) |cand| {
            const in_region = if (cand.admin1) |a| std.ascii.eqlIgnoreCase(a, prefer) else false;
            const in_country = if (cand.country) |cn| std.ascii.eqlIgnoreCase(cn, prefer) else false;
            if (in_region or in_country) {
                g = cand;
                break;
            }
        }
    }
    const lat = g.latitude orelse return .not_found;
    const lon = g.longitude orelse return .not_found;
    if (!validCoords(lat, lon)) return .not_found;
    var p = Place{ .lat = lat, .lon = lon };
    p.city.set(g.name orelse "");
    p.country.set(g.country orelse g.country_code orelse "");
    return .{ .found = p };
}

// --- place helpers -------------------------------------------------------------

/// "32.59,-96.86" (latitude,longitude) — the old weather-location form.
pub fn parseCoordPair(s: []const u8) ?[2]f64 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const a = std.mem.trim(u8, s[0..comma], " \t");
    const b = std.mem.trim(u8, s[comma + 1 ..], " \t");
    if (a.len == 0 or b.len == 0) return null;
    const lat = std.fmt.parseFloat(f64, a) catch return null;
    const lon = std.fmt.parseFloat(f64, b) catch return null;
    if (!validCoords(lat, lon)) return null;
    return .{ lat, lon };
}

const UsState = struct { code: []const u8, name: []const u8 };
const US_STATES = [_]UsState{
    .{ .code = "AL", .name = "Alabama" },        .{ .code = "AK", .name = "Alaska" },
    .{ .code = "AZ", .name = "Arizona" },        .{ .code = "AR", .name = "Arkansas" },
    .{ .code = "CA", .name = "California" },     .{ .code = "CO", .name = "Colorado" },
    .{ .code = "CT", .name = "Connecticut" },    .{ .code = "DE", .name = "Delaware" },
    .{ .code = "DC", .name = "District of Columbia" }, .{ .code = "FL", .name = "Florida" },
    .{ .code = "GA", .name = "Georgia" },        .{ .code = "HI", .name = "Hawaii" },
    .{ .code = "ID", .name = "Idaho" },          .{ .code = "IL", .name = "Illinois" },
    .{ .code = "IN", .name = "Indiana" },        .{ .code = "IA", .name = "Iowa" },
    .{ .code = "KS", .name = "Kansas" },         .{ .code = "KY", .name = "Kentucky" },
    .{ .code = "LA", .name = "Louisiana" },      .{ .code = "ME", .name = "Maine" },
    .{ .code = "MD", .name = "Maryland" },       .{ .code = "MA", .name = "Massachusetts" },
    .{ .code = "MI", .name = "Michigan" },       .{ .code = "MN", .name = "Minnesota" },
    .{ .code = "MS", .name = "Mississippi" },    .{ .code = "MO", .name = "Missouri" },
    .{ .code = "MT", .name = "Montana" },        .{ .code = "NE", .name = "Nebraska" },
    .{ .code = "NV", .name = "Nevada" },         .{ .code = "NH", .name = "New Hampshire" },
    .{ .code = "NJ", .name = "New Jersey" },     .{ .code = "NM", .name = "New Mexico" },
    .{ .code = "NY", .name = "New York" },       .{ .code = "NC", .name = "North Carolina" },
    .{ .code = "ND", .name = "North Dakota" },   .{ .code = "OH", .name = "Ohio" },
    .{ .code = "OK", .name = "Oklahoma" },       .{ .code = "OR", .name = "Oregon" },
    .{ .code = "PA", .name = "Pennsylvania" },   .{ .code = "RI", .name = "Rhode Island" },
    .{ .code = "SC", .name = "South Carolina" }, .{ .code = "SD", .name = "South Dakota" },
    .{ .code = "TN", .name = "Tennessee" },      .{ .code = "TX", .name = "Texas" },
    .{ .code = "UT", .name = "Utah" },           .{ .code = "VT", .name = "Vermont" },
    .{ .code = "VA", .name = "Virginia" },       .{ .code = "WA", .name = "Washington" },
    .{ .code = "WV", .name = "West Virginia" },  .{ .code = "WI", .name = "Wisconsin" },
    .{ .code = "WY", .name = "Wyoming" },
};

fn usStateName(code: []const u8) ?[]const u8 {
    for (US_STATES) |st| {
        if (std.ascii.eqlIgnoreCase(st.code, code)) return st.name;
    }
    return null;
}

fn inList(s: []const u8, list: []const []const u8) bool {
    for (list) |x| {
        if (std.ascii.eqlIgnoreCase(s, x)) return true;
    }
    return false;
}

/// The United States and its territories, by name or ISO code.
const US_NAMES = [_][]const u8{
    "US",                       "USA",          "United States", "United States of America",
    "PR",                       "Puerto Rico",  "GU",            "Guam",
    "VI",                       "U.S. Virgin Islands", "AS",     "American Samoa",
    "MP",                       "Northern Mariana Islands",
};
/// Other countries that report temperatures in °F.
const OTHER_FAHRENHEIT = [_][]const u8{
    "LR", "Liberia", "KY", "Cayman Islands", "BS", "Bahamas", "BZ", "Belize",
    "PW", "Palau", "FM", "Micronesia", "MH", "Marshall Islands",
};
/// Time zones of US places, for coordinates with no country attached.
const US_TIMEZONES = [_][]const u8{
    "America/New_York", "America/Chicago",    "America/Denver",       "America/Phoenix",
    "America/Los_Angeles", "America/Anchorage", "America/Juneau",     "America/Sitka",
    "America/Yakutat",  "America/Nome",       "America/Metlakatla",   "America/Adak",
    "America/Boise",    "America/Detroit",    "America/Menominee",    "America/Indiana/",
    "America/Kentucky/", "America/North_Dakota/", "America/Puerto_Rico", "Pacific/Honolulu",
    "Pacific/Guam",     "Pacific/Saipan",     "Pacific/Pago_Pago",    "America/St_Thomas",
};

/// True for a place in the United States: by its country when known,
/// else by its time zone.
pub fn usPlace(country: []const u8, timezone: []const u8) bool {
    if (country.len > 0) return inList(country, &US_NAMES);
    for (US_TIMEZONES) |tz| {
        if (std.mem.startsWith(u8, timezone, tz)) return true;
    }
    return false;
}

/// The units a place reads its weather in.
pub fn autoUnits(country: []const u8, timezone: []const u8) Units {
    if (usPlace(country, timezone)) return .fahrenheit;
    if (country.len > 0 and inList(country, &OTHER_FAHRENHEIT)) return .fahrenheit;
    return .celsius;
}

// --- the service -------------------------------------------------------------

pub const Config = struct {
    latitude: ?f64 = null,
    longitude: ?f64 = null,
    /// With coordinates: the display label. Without: geocoded to find them.
    city: []const u8 = "",
    auto_location: bool = true,
    units: Units = .celsius,
    /// Pick °C/°F from the place (shell.json weather_units "auto").
    units_auto: bool = false,
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    ip_url: []const u8 = DEFAULT_IP_URL,
    /// Shared answer cache (defaultCachePath); empty = no cache.
    cache_path: []const u8 = "",
};

/// The weather_* keys of ~/.config/perihelionbar/shell.json, for std.json
/// with ignore_unknown_fields. The shell owns that file; the bar only reads
/// these keys from it, so both show the same place and units.
pub const ShellJsonKeys = struct {
    weather_latitude: ?f64 = null,
    weather_longitude: ?f64 = null,
    weather_city: ?[]const u8 = null,
    weather_units: ?[]const u8 = null,
    weather_auto_location: ?bool = null,
    weather_refresh_minutes: ?u32 = null,
    weather_ip_url: ?[]const u8 = null,
};

/// Config from those keys, with the shell's defaults (units from the
/// place, IP location, 15 min). Strings are borrowed from `k`; Service.init
/// copies them.
pub fn configFromKeys(k: ShellJsonKeys, cache_path: []const u8) Config {
    const minutes = std.math.clamp(k.weather_refresh_minutes orelse 15, 1, 1440);
    const units_text = k.weather_units orelse "auto";
    const fixed = Units.parse(units_text);
    return .{
        .latitude = k.weather_latitude,
        .longitude = k.weather_longitude,
        .city = k.weather_city orelse "",
        .auto_location = k.weather_auto_location orelse true,
        .units = fixed orelse .celsius,
        .units_auto = fixed == null, // "auto", or anything unrecognised
        .refresh_ms = @as(i64, minutes) * 60_000,
        .ip_url = k.weather_ip_url orelse "",
        .cache_path = cache_path,
    };
}

/// $XDG_CACHE_HOME/perihelionbar/weather.cache, else
/// ~/.cache/perihelionbar/weather.cache. Empty when neither resolves.
pub fn defaultCachePath(buf: []u8) []const u8 {
    if (libc.getenv("XDG_CACHE_HOME")) |x| {
        const xs = std.mem.span(x);
        if (xs.len > 0) return std.fmt.bufPrint(buf, "{s}/perihelionbar/weather.cache", .{xs}) catch "";
    }
    const home = std.mem.span(libc.getenv("HOME") orelse return "");
    return std.fmt.bufPrint(buf, "{s}/.cache/perihelionbar/weather.cache", .{home}) catch "";
}

// --- shared answer cache ------------------------------------------------------
//
// Plain text so it's easy to inspect: a header naming when and for which
// location source the answer was fetched, then Open-Meteo's JSON as-is.
//
//   perihelion-weather 2
//   <unix seconds fetched>
//   <source key: "coords …" / "city … auto=1" / "ip …">
//   <lat> <lon>
//   <city>
//   <country>
//   <body length in bytes>
//   {…open-meteo json…}
//
// Concurrency (bar and shell both read and write it), without locks:
//   - Writers never touch the live file: each writes "<path>.<pid>.tmp"
//     (pid-unique, so two writers never share a temp file) and rename()s it
//     over the cache. rename() within one directory is atomic, so a reader
//     opens either the whole old file or the whole new one, never a mix.
//   - A failed or short write is unlinked, never renamed into place.
//   - Readers still verify: magic line, every header field, and the body
//     length must match exactly, then the body must parse as a forecast.
//     Anything else (a hand edit, a file from an older format, a disk that
//     filled up) is ignored and the reader fetches for itself.
//   - Last writer wins. Both answers are valid, so no lock is needed; at
//     worst one extra request happens when both start at the same moment.
//   - Wall-clock time (not monotonic) dates entries, since the two
//     processes share no clock. An entry dated in the future (clock moved
//     back) is ignored, and the next fetch overwrites it.

const CACHE_MAGIC = "perihelion-weather 2";
const CACHE_MAX: usize = 12288;
/// An expired entry still beats a blank card while the first fetch of a
/// session is running or failing (offline at login); shown marked stale.
const CACHE_STALE_MAX_S: i64 = 6 * 3600;

const CacheEntry = struct {
    fetched_s: i64,
    key: []const u8,
    lat: f64,
    lon: f64,
    city: []const u8,
    country: []const u8,
    body: []const u8,
};

fn formatCacheHeader(out: []u8, fetched_s: i64, key: []const u8, lat: f64, lon: f64, city: []const u8, country: []const u8, body_len: usize) ?[]const u8 {
    return std.fmt.bufPrint(out, CACHE_MAGIC ++ "\n{d}\n{s}\n{d:.6} {d:.6}\n{s}\n{s}\n{d}\n", .{ fetched_s, key, lat, lon, city, country, body_len }) catch null;
}

fn parseCache(bytes: []const u8) ?CacheEntry {
    var it = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, it.next() orelse return null, CACHE_MAGIC)) return null;
    const fetched_s = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
    const key = it.next() orelse return null;
    const ll = it.next() orelse return null;
    const sp = std.mem.indexOfScalar(u8, ll, ' ') orelse return null;
    const lat = std.fmt.parseFloat(f64, ll[0..sp]) catch return null;
    const lon = std.fmt.parseFloat(f64, ll[sp + 1 ..]) catch return null;
    const city = it.next() orelse return null;
    const country = it.next() orelse return null;
    const body_len = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
    const body = it.rest();
    // Exact length: catches truncation and trailing junk alike.
    if (body.len != body_len or body_len == 0) return null;
    return .{ .fetched_s = fetched_s, .key = key, .lat = lat, .lon = lon, .city = city, .country = country, .body = body };
}

/// Whole small file into `buf`; null when missing, unreadable or too big.
fn readSmallFile(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const raw_fd = posix.system.open(path.ptr, .{ .ACCMODE = .RDONLY }, @as(posix.mode_t, 0));
    if (raw_fd < 0) return null;
    const fd: posix.fd_t = @intCast(raw_fd);
    defer _ = posix.system.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = posix.read(fd, buf[len..]) catch return null;
        if (n == 0) return buf[0..len];
        len += n;
    }
    return null; // filled the buffer: not a file we wrote
}

fn writeAll(fd: posix.fd_t, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

/// mkdir -p for the directories above `path` (best effort; EEXIST is fine).
fn mkdirParents(path: []const u8) void {
    var buf: [400]u8 = undefined;
    if (path.len >= buf.len) return;
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        _ = posix.system.mkdir(buf[0..i :0].ptr, 0o755);
    }
}

pub const RequestKind = enum { ip_locate, geocode, forecast };

/// What the card should say when there's no reading to show.
pub const Status = enum { ready, locating, fetching, waiting, no_location, city_not_found };

pub const Service = struct {
    units: Units = .celsius,
    units_auto: bool = false,
    refresh_ms: i64 = DEFAULT_REFRESH_MS,
    auto_location: bool = true,
    /// Coordinates came from config, never re-resolved.
    manual: bool = false,
    query: BoundedText(96) = .{},
    /// The query as geocoded: the name searched, a country code to narrow
    /// it to, and a region or country name to prefer among the results.
    geo_name: BoundedText(96) = .{},
    geo_cc: BoundedText(2) = .{},
    geo_region: BoundedText(48) = .{},
    ip_url: BoundedText(200) = .{},
    geocode_failed: bool = false,
    cache_path: BoundedText(380) = .{},
    /// Which configured location the cache entry must match (empty = the
    /// config names no location source, so nothing is cached).
    source_key: BoundedText(320) = .{},
    /// Wall-clock second `data` was fetched at (by us or via the cache).
    data_fetched_s: i64 = 0,

    located: bool = false,
    lat: f64 = 0,
    lon: f64 = 0,
    loc_city: Name = .{},
    loc_country: Name = .{},

    data: Weather = .{},

    in_flight: ?RequestKind = null,
    next_due_ms: i64 = 0,
    last_forecast_ms: ?i64 = null,
    attempts: u8 = 0,
    backoff_level: u8 = 0,
    url_buf: [768]u8 = undefined,

    pub fn init(cfg: Config) Service {
        var s = Service{
            .units = cfg.units,
            .units_auto = cfg.units_auto,
            .refresh_ms = @max(cfg.refresh_ms, MIN_REFRESH_MS),
            .auto_location = cfg.auto_location,
        };
        s.query.set(std.mem.trim(u8, cfg.city, " \t\r\n"));
        s.ip_url.set(if (cfg.ip_url.len > 0) cfg.ip_url else DEFAULT_IP_URL);
        if (cfg.latitude) |lat| {
            if (cfg.longitude) |lon| {
                if (validCoords(lat, lon)) {
                    s.manual = true;
                    s.located = true;
                    s.lat = lat;
                    s.lon = lon;
                    s.loc_city.set(s.query.slice());
                }
            }
        }
        // "lat,lon" written as the place: coordinates, named from the
        // forecast's time zone.
        if (!s.located) {
            if (parseCoordPair(s.query.slice())) |ll| {
                s.manual = true;
                s.located = true;
                s.lat = ll[0];
                s.lon = ll[1];
            }
        }
        if (!s.manual) s.splitQuery();
        if (!s.located and s.query.len == 0 and !s.auto_location) s.data.loading = false;
        s.cache_path.set(cfg.cache_path);
        var kb: [320]u8 = undefined;
        const key: []const u8 = if (s.manual)
            std.fmt.bufPrint(&kb, "coords {d:.4},{d:.4} {s}", .{ s.lat, s.lon, s.query.slice() }) catch ""
        else if (s.query.len > 0)
            std.fmt.bufPrint(&kb, "city {s} auto={d}", .{ s.query.slice(), @intFromBool(s.auto_location) }) catch ""
        else if (s.auto_location)
            std.fmt.bufPrint(&kb, "ip {s}", .{s.ip_url.slice()}) catch ""
        else
            "";
        s.source_key.set(key);
        return s;
    }

    /// Applies a re-read config (the bar, after a SIGUSR1). Units and the
    /// refresh period change in place, keeping the reading; a different
    /// place or cache file starts over from no data.
    pub fn reconfigure(self: *Service, cfg: Config) void {
        const next = Service.init(cfg);
        if (!self.sameLocationConfig(&next)) {
            self.* = next;
            return;
        }
        self.units = next.units;
        self.units_auto = next.units_auto;
        self.applyAutoUnits();
        if (next.refresh_ms != self.refresh_ms) {
            self.refresh_ms = next.refresh_ms;
            // Re-aim a scheduled refresh at the new period (a pending retry
            // or backoff keeps its own timing).
            if (self.attempts == 0 and self.backoff_level == 0 and self.in_flight == null) {
                if (self.last_forecast_ms) |t| self.next_due_ms = t + self.refresh_ms;
            }
        }
    }

    /// "City, ST" → Texas, US; "City, FR" → France; "City, Region" → prefer
    /// that region or country; anything else is searched as written.
    fn splitQuery(self: *Service) void {
        const q = self.query.slice();
        self.geo_name.set(q);
        const comma = std.mem.indexOfScalar(u8, q, ',') orelse return;
        const name = std.mem.trim(u8, q[0..comma], " \t");
        const region = std.mem.trim(u8, q[comma + 1 ..], " \t");
        if (name.len == 0 or region.len == 0) return;
        self.geo_name.set(name);
        if (region.len == 2 and std.ascii.isAlphabetic(region[0]) and std.ascii.isAlphabetic(region[1])) {
            const up = [2]u8{ std.ascii.toUpper(region[0]), std.ascii.toUpper(region[1]) };
            if (usStateName(&up)) |state| {
                self.geo_cc.set("US");
                self.geo_region.set(state);
            } else {
                self.geo_cc.set(&up);
            }
            return;
        }
        self.geo_region.set(region);
    }

    /// With units_auto: °C/°F from the place's country, else its time zone
    /// (bare coordinates). Leaves the units alone until either is known.
    fn applyAutoUnits(self: *Service) void {
        if (!self.units_auto) return;
        const country = if (self.loc_country.len > 0) self.loc_country.slice() else self.data.country.slice();
        const tz = self.data.timezone.slice();
        if (country.len == 0 and tz.len == 0) return;
        self.units = autoUnits(country, tz);
    }

    /// A page with the full forecast for this place: weather.gov in the
    /// US, Windy elsewhere. Null until the place is known.
    pub fn forecastUrl(self: *const Service, out: []u8) ?[]const u8 {
        if (!self.located) return null;
        const country = if (self.loc_country.len > 0) self.loc_country.slice() else self.data.country.slice();
        if (usPlace(country, self.data.timezone.slice())) {
            return std.fmt.bufPrint(out, "https://forecast.weather.gov/MapClick.php?lat={d:.4}&lon={d:.4}", .{ self.lat, self.lon }) catch null;
        }
        return std.fmt.bufPrint(out, "https://www.windy.com/?{d:.4},{d:.4},9", .{ self.lat, self.lon }) catch null;
    }

    /// Everything that decides *where* the weather is for, or where it's
    /// cached. Units and refresh period are deliberately not in here.
    fn sameLocationConfig(self: *const Service, o: *const Service) bool {
        return self.manual == o.manual and
            (!self.manual or (self.lat == o.lat and self.lon == o.lon)) and
            self.auto_location == o.auto_location and
            std.mem.eql(u8, self.query.slice(), o.query.slice()) and
            std.mem.eql(u8, self.ip_url.slice(), o.ip_url.slice()) and
            std.mem.eql(u8, self.cache_path.slice(), o.cache_path.slice());
    }

    /// Top-bar shape: "<icon> 72°F" (Nerd Font icon, day/night aware).
    /// Empty until the first reading arrives.
    pub fn compactLabel(self: *const Service, out: []u8) []const u8 {
        const d = &self.data;
        if (!d.available) return "";
        var ib: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(iconFor(d.w_code, d.is_day)), &ib) catch return "";
        return std.fmt.bufPrint(out, "{s} {d}\u{00B0}{s}", .{ ib[0..n], roundi(d.temp(self.units)), self.units.tag() }) catch "";
    }

    pub fn status(self: *const Service) Status {
        if (self.data.available) return .ready;
        if (self.in_flight) |k| return if (k == .forecast) .fetching else .locating;
        if (!self.located) {
            if (self.query.len > 0 and !self.manual and self.geocode_failed and !self.auto_location) return .city_not_found;
            if (self.query.len == 0 and !self.auto_location) return .no_location;
        }
        return .waiting;
    }

    /// Next URL to fetch, or null when nothing is due (or one is in flight).
    /// The caller must answer every returned URL with complete().
    pub fn poll(self: *Service, now_ms: i64) ?[:0]const u8 {
        if (self.in_flight != null) return null;
        if (now_ms < self.next_due_ms) return null;
        // The other process (bar or desktop card) may have just fetched.
        if (self.tryCache(now_ms)) return null;
        const kind: RequestKind = blk: {
            if (self.located) break :blk .forecast;
            if (self.query.len > 0 and !self.geocode_failed) break :blk .geocode;
            if (self.auto_location) break :blk .ip_locate;
            // Nothing to resolve a location from: sleep until reconfigured.
            self.data.loading = false;
            self.next_due_ms = std.math.maxInt(i64);
            return null;
        };
        if (kind == .forecast) {
            if (self.last_forecast_ms) |t| {
                if (now_ms - t < MIN_FETCH_INTERVAL_MS) {
                    self.next_due_ms = t + MIN_FETCH_INTERVAL_MS;
                    return null;
                }
            }
        }
        const url = self.buildUrl(kind) orelse return null;
        if (kind == .forecast) self.last_forecast_ms = now_ms;
        self.in_flight = kind;
        self.data.loading = true;
        return url;
    }

    /// The fetch started by poll() ended; `body` is everything it printed
    /// (empty on network failure — curl --fail prints nothing on HTTP errors).
    pub fn complete(self: *Service, body: []const u8, now_ms: i64) void {
        const kind = self.in_flight orelse return;
        self.in_flight = null;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        const ok = trimmed.len > 0 and trimmed[0] == '{' and switch (kind) {
            .forecast => blk: {
                var w: Weather = undefined;
                if (!parseForecast(trimmed, self.loc_city.slice(), self.loc_country.slice(), &w)) break :blk false;
                self.data = w;
                self.data_fetched_s = wallSeconds();
                self.applyAutoUnits();
                self.storeCache(trimmed);
                break :blk true;
            },
            .ip_locate => blk: {
                const p = parseIpLocation(trimmed) orelse break :blk false;
                self.setPlace(p);
                break :blk true;
            },
            .geocode => switch (parseGeocode(trimmed, self.geo_region.slice())) {
                .found => |p| blk: {
                    self.setPlace(p);
                    break :blk true;
                },
                .not_found => {
                    // A typo won't fix itself on retry: fall through to IP
                    // geolocation if allowed, else report it on the card.
                    self.geocode_failed = true;
                    if (!self.auto_location) self.data.loading = false;
                    self.next_due_ms = now_ms;
                    return;
                },
                .failed => false,
            },
        };
        if (!ok) return self.fail(now_ms);
        if (kind == .forecast) {
            self.attempts = 0;
            self.backoff_level = 0;
            self.next_due_ms = now_ms + self.nextInterval(now_ms);
        } else {
            // Located: fetch the forecast straight away.
            self.next_due_ms = now_ms;
        }
    }

    /// Refetch now (subject to the 30 s floor).
    pub fn forceRefresh(self: *Service, now_ms: i64) void {
        self.next_due_ms = now_ms;
        self.attempts = 0;
    }

    /// Adopts the shared cache when it holds a fresh answer for our
    /// location source that is newer than what we show. Reschedules so the
    /// process that fetched stays the one fetching: we come back a minute
    /// after its next refresh and pick that answer up too.
    fn tryCache(self: *Service, now_ms: i64) bool {
        if (self.cache_path.len == 0 or self.source_key.len == 0) return false;
        var path_buf: [400]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{self.cache_path.slice()}) catch return false;
        var buf: [CACHE_MAX]u8 = undefined;
        const bytes = readSmallFile(path, &buf) orelse return false;
        const e = parseCache(bytes) orelse return false;
        if (!std.mem.eql(u8, e.key, self.source_key.slice())) return false;
        if (!validCoords(e.lat, e.lon)) return false;
        const age_s = wallSeconds() - e.fetched_s;
        if (age_s < 0) return false; // dated in the future: clock moved back
        const age_ms = age_s * 1000;
        if (age_ms >= self.refresh_ms) {
            // Expired. With nothing on screen yet, show it marked stale so
            // the card isn't blank while we fetch — but keep fetching, and
            // don't take its location (an IP guess may be out of date).
            if (!self.data.available and age_s < CACHE_STALE_MAX_S) {
                var sw: Weather = undefined;
                if (parseForecast(e.body, e.city, e.country, &sw)) {
                    sw.stale = true;
                    sw.loading = true;
                    self.data = sw;
                    self.data_fetched_s = e.fetched_s;
                    self.applyAutoUnits();
                }
            }
            return false;
        }
        if (self.data.available and e.fetched_s <= self.data_fetched_s) return false;
        var w: Weather = undefined;
        if (!parseForecast(e.body, e.city, e.country, &w)) return false;
        self.data = w;
        self.data_fetched_s = e.fetched_s;
        self.located = true;
        self.lat = e.lat;
        self.lon = e.lon;
        self.loc_city.set(e.city);
        self.loc_country.set(e.country);
        self.applyAutoUnits();
        self.attempts = 0;
        self.backoff_level = 0;
        self.last_forecast_ms = now_ms - age_ms;
        self.next_due_ms = now_ms + @max(self.nextInterval(now_ms) - age_ms, 0) + MIN_REFRESH_MS;
        return true;
    }

    /// Writes the answer we just fetched for the other process (temp file
    /// + rename, so a reader never sees half a file).
    fn storeCache(self: *const Service, body: []const u8) void {
        if (self.cache_path.len == 0 or self.source_key.len == 0) return;
        if (body.len + 1024 > CACHE_MAX) return;
        const city = self.loc_city.slice();
        const country = self.loc_country.slice();
        for ([_][]const u8{ city, country, self.source_key.slice() }) |f| {
            if (std.mem.indexOfAny(u8, f, "\r\n") != null) return; // would break the header
        }
        var head_buf: [1024]u8 = undefined;
        const head = formatCacheHeader(&head_buf, self.data_fetched_s, self.source_key.slice(), self.lat, self.lon, city, country, body.len) orelse return;
        var path_buf: [400]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{self.cache_path.slice()}) catch return;
        mkdirParents(path);
        var tmp_buf: [430]u8 = undefined;
        const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.{d}.tmp", .{ path, std.c.getpid() }) catch return;
        const raw_fd = posix.system.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(posix.mode_t, 0o644));
        if (raw_fd < 0) return;
        const fd: posix.fd_t = @intCast(raw_fd);
        const ok = writeAll(fd, head) and writeAll(fd, body);
        _ = posix.system.close(fd);
        if (!ok or std.c.rename(tmp.ptr, path.ptr) != 0) _ = libc.unlink(tmp.ptr);
    }

    fn setPlace(self: *Service, p: Place) void {
        self.located = true;
        self.lat = p.lat;
        self.lon = p.lon;
        self.loc_city = p.city;
        self.loc_country = p.country;
        self.applyAutoUnits();
    }

    fn fail(self: *Service, now_ms: i64) void {
        if (self.data.available) self.data.stale = true;
        self.attempts += 1;
        if (self.attempts < MAX_RETRIES) {
            self.next_due_ms = now_ms + RETRY_DELAY_MS;
            return;
        }
        self.attempts = 0;
        self.data.loading = false;
        const shift: u6 = @intCast(@min(self.backoff_level, 8));
        const delay = @min(BACKOFF_BASE_MS << shift, BACKOFF_CAP_MS);
        self.backoff_level +|= 1;
        self.next_due_ms = now_ms + delay;
    }

    /// Refresh period with +/- 7.5 s jitter (so a fleet of
    /// shells started together doesn't hit the API in lockstep).
    fn nextInterval(self: *const Service, seed: i64) i64 {
        const h: u64 = @as(u64, @bitCast(seed)) *% 0x9E3779B97F4A7C15;
        const span: u64 = @intCast(2 * JITTER_MS + 1);
        const jitter = @as(i64, @intCast((h >> 33) % span)) - JITTER_MS;
        return @max(MIN_REFRESH_MS, self.refresh_ms + jitter);
    }

    fn buildUrl(self: *Service, kind: RequestKind) ?[:0]const u8 {
        return switch (kind) {
            .forecast => std.fmt.bufPrintZ(
                &self.url_buf,
                "{s}?latitude={d:.4}&longitude={d:.4}&current={s}&daily={s}&timezone=auto&forecast_days={d}",
                .{ FORECAST_URL, self.lat, self.lon, CURRENT_FIELDS, DAILY_FIELDS, FORECAST_DAYS },
            ) catch null,
            .geocode => blk: {
                var enc_buf: [300]u8 = undefined;
                const enc = percentEncode(self.geo_name.slice(), &enc_buf) orelse break :blk null;
                // Narrowed searches look at more results to find the region.
                const count: u8 = if (self.geo_cc.len > 0 or self.geo_region.len > 0) 10 else 1;
                if (self.geo_cc.len > 0) {
                    break :blk std.fmt.bufPrintZ(
                        &self.url_buf,
                        "{s}?name={s}&count={d}&language=en&format=json&countryCode={s}",
                        .{ GEOCODE_URL, enc, count, self.geo_cc.slice() },
                    ) catch null;
                }
                break :blk std.fmt.bufPrintZ(
                    &self.url_buf,
                    "{s}?name={s}&count={d}&language=en&format=json",
                    .{ GEOCODE_URL, enc, count },
                ) catch null;
            },
            .ip_locate => std.fmt.bufPrintZ(&self.url_buf, "{s}", .{self.ip_url.slice()}) catch null,
        };
    }
};

// --- tests -------------------------------------------------------------------
// zig build test-weather (perihelionbar/), or zig test -lc src/weather.zig

const SAMPLE_FORECAST =
    \\{"latitude":41.88,"longitude":-87.63,"timezone":"America/Chicago",
    \\"current_units":{"time":"iso8601","temperature_2m":"°C","wind_speed_10m":"km/h"},
    \\"current":{"time":"2026-11-18T12:00","interval":900,"temperature_2m":4.6,
    \\"relative_humidity_2m":71,"apparent_temperature":0.4,"is_day":1,"precipitation":0.0,
    \\"weather_code":3,"surface_pressure":1002.3,"wind_speed_10m":18.7},
    \\"daily":{"time":["2026-11-18","2026-11-19","2026-11-20"],
    \\"sunrise":["2026-11-18T06:42","2026-11-19T06:43","2026-11-20T06:44"],
    \\"sunset":["2026-11-18T16:28","2026-11-19T16:27","2026-11-20T16:27"],
    \\"temperature_2m_max":[6.1,9.4,null],"temperature_2m_min":[1.2,3.3,-2.0],
    \\"weather_code":[3,61,71],"precipitation_probability_max":[10,80,null],
    \\"uv_index_max":[1.35,0.9,1.1]}}
;

test "parse Open-Meteo forecast" {
    var w: Weather = undefined;
    try std.testing.expect(parseForecast(SAMPLE_FORECAST, "", "", &w));
    try std.testing.expect(w.available and !w.loading and w.is_day);
    try std.testing.expectEqual(@as(i32, 5), roundi(w.temp_c));
    try std.testing.expectEqual(@as(i32, 40), roundi(w.temp_f));
    try std.testing.expectEqual(@as(u32, 3), w.w_code);
    try std.testing.expectEqual(@as(u32, 71), w.humidity);
    try std.testing.expectEqualStrings("19 km/h", w.wind.slice());
    try std.testing.expectEqualStrings("Chicago", w.city.slice());
    try std.testing.expectEqualStrings("06:42", w.sunrise.slice());
    try std.testing.expectEqualStrings("16:28", w.sunset.slice());
    try std.testing.expectEqual(@as(usize, 3), w.forecast_len);
    try std.testing.expectEqualStrings("Wed", w.forecast[0].day_name.slice());
    try std.testing.expectEqualStrings("Thu", w.forecast[1].day_name.slice());
    try std.testing.expectEqual(@as(u32, 80), w.forecast[1].precip_prob);
    // nulls inside daily arrays degrade to 0 instead of failing the parse
    try std.testing.expectEqual(@as(f32, 0), w.forecast[2].max_c);
    try std.testing.expectEqualStrings("12:00", w.observed.slice());
    const ev = w.nextSunEvent().?;
    try std.testing.expect(!ev.sunrise);
    try std.testing.expectEqualStrings("16:28", ev.at);
    // Same evening after dark: tomorrow's sunrise.
    w.is_day = false;
    w.observed.set("21:15");
    try std.testing.expectEqualStrings("06:43", w.nextSunEvent().?.at);
    try std.testing.expectEqual(@as(u32, 0), w.forecast[2].precip_prob);
}

test "forecast parse rejects error and garbage answers" {
    var w: Weather = undefined;
    try std.testing.expect(!parseForecast("{\"error\":true,\"reason\":\"Latitude must be in range\"}", "", "", &w));
    try std.testing.expect(!parseForecast("{\"current\":{\"temperature_2m\":1", "", "", &w));
    try std.testing.expect(!parseForecast("", "", "", &w));
}

test "ip geolocation: ipapi.co and ip-api.com shapes" {
    const a = parseIpLocation("{\"ip\":\"1.2.3.4\",\"city\":\"Austin\",\"country\":\"US\",\"country_name\":\"United States\",\"latitude\":30.27,\"longitude\":-97.74}").?;
    try std.testing.expectEqualStrings("Austin", a.city.slice());
    try std.testing.expectEqualStrings("United States", a.country.slice());
    const b = parseIpLocation("{\"status\":\"success\",\"country\":\"Germany\",\"city\":\"Berlin\",\"lat\":52.52,\"lon\":13.4}").?;
    try std.testing.expectEqualStrings("Germany", b.country.slice());
    try std.testing.expect(parseIpLocation("{\"error\":true,\"reason\":\"RateLimited\"}") == null);
    try std.testing.expect(parseIpLocation("{\"status\":\"fail\",\"message\":\"reserved range\"}") == null);
}

test "geocode results" {
    const found = parseGeocode("{\"results\":[{\"name\":\"Lyon\",\"latitude\":45.75,\"longitude\":4.85,\"country\":\"France\"}]}", "");
    try std.testing.expect(found == .found);
    try std.testing.expectEqualStrings("Lyon", found.found.city.slice());
    try std.testing.expect(parseGeocode("{\"generationtime_ms\":0.5}", "") == .not_found);
    try std.testing.expect(parseGeocode("not json", "") == .failed);
}

test "weather code mapping" {
    try std.testing.expectEqual(Kind.clear, kindFor(1));
    try std.testing.expectEqual(Kind.freezing, kindFor(66));
    try std.testing.expectEqual(Kind.snow_showers, kindFor(86));
    try std.testing.expectEqualStrings("Thunderstorm with hail", conditionText(99));
    try std.testing.expectEqual(@as(u32, 0xE30D), iconFor(0, true));
    try std.testing.expectEqual(@as(u32, 0xE32B), iconFor(0, false));
    try std.testing.expectEqual(@as(u32, 0xE374), iconFor(42, true));
    try std.testing.expectEqual(@as(u32, 0), tintFor(42, true));
}

test "service: manual coords fetch forecast first, then wait the interval" {
    var s = Service.init(.{ .latitude = 41.88, .longitude = -87.63, .city = "Chicago" });
    const url = s.poll(1_000).?;
    try std.testing.expect(std.mem.startsWith(u8, url, FORECAST_URL ++ "?latitude=41.8800&longitude=-87.6300&current="));
    try std.testing.expect(std.mem.endsWith(u8, url, "&timezone=auto&forecast_days=7"));
    try std.testing.expect(s.poll(1_001) == null); // in flight
    s.complete(SAMPLE_FORECAST, 2_000);
    try std.testing.expectEqual(Status.ready, s.status());
    try std.testing.expectEqualStrings("Chicago", s.data.city.slice());
    try std.testing.expect(s.next_due_ms >= 2_000 + DEFAULT_REFRESH_MS - JITTER_MS);
    try std.testing.expect(s.next_due_ms <= 2_000 + DEFAULT_REFRESH_MS + JITTER_MS);
    try std.testing.expect(s.poll(2_000 + 60_000) == null);
}

test "service: retries 3x at 30 s, then backs off, keeping stale data" {
    var s = Service.init(.{ .latitude = 1, .longitude = 2 });
    _ = s.poll(0).?;
    s.complete(SAMPLE_FORECAST, 0);
    var now: i64 = s.next_due_ms;
    _ = s.poll(now).?;
    s.complete("", now); // attempt 1 failed
    try std.testing.expect(s.data.available and s.data.stale);
    try std.testing.expectEqual(now + RETRY_DELAY_MS, s.next_due_ms);
    now = s.next_due_ms;
    _ = s.poll(now).?;
    s.complete("", now); // attempt 2
    now = s.next_due_ms;
    _ = s.poll(now).?;
    s.complete("", now); // attempt 3 → backoff 60 s
    try std.testing.expectEqual(now + BACKOFF_BASE_MS, s.next_due_ms);
    // Persistent backoff doubles up to the 5-minute cap.
    for (0..3) |_| {
        for (0..MAX_RETRIES) |_| {
            now = s.next_due_ms;
            _ = s.poll(now).?;
            s.complete("", now);
        }
    }
    try std.testing.expectEqual(now + BACKOFF_CAP_MS, s.next_due_ms);
}

test "service: min fetch interval holds forced refreshes" {
    var s = Service.init(.{ .latitude = 1, .longitude = 2 });
    _ = s.poll(10_000).?;
    s.complete(SAMPLE_FORECAST, 10_500);
    s.forceRefresh(12_000);
    try std.testing.expect(s.poll(12_000) == null);
    try std.testing.expectEqual(@as(i64, 40_000), s.next_due_ms);
    try std.testing.expect(s.poll(40_000) != null);
}

test "service: city geocodes, then falls back to IP when not found" {
    var s = Service.init(.{ .city = "Saint Paul, MN" });
    const g = s.poll(0).?;
    try std.testing.expectEqualStrings(GEOCODE_URL ++ "?name=Saint%20Paul&count=10&language=en&format=json&countryCode=US", g);
    s.complete("{\"generationtime_ms\":0.3}", 100);
    const ip = s.poll(100).?;
    try std.testing.expectEqualStrings(DEFAULT_IP_URL, ip);
    s.complete("{\"city\":\"Saint Paul\",\"country_name\":\"United States\",\"latitude\":44.95,\"longitude\":-93.09}", 200);
    const f = s.poll(200).?;
    try std.testing.expect(std.mem.indexOf(u8, f, "latitude=44.9500") != null);
}

test "place text: coordinates, US state, country code, region name" {
    const t = std.testing;
    // "lat,lon" is a manual location, named later from the time zone.
    var c = Service.init(.{ .city = "32.59, -96.86" });
    try t.expect(c.manual and c.located);
    try t.expectApproxEqAbs(@as(f64, -96.86), c.lon, 1e-9);
    try t.expect(std.mem.indexOf(u8, c.poll(0).?, "latitude=32.5900&longitude=-96.8600") != null);
    try t.expect(parseCoordPair("DeSoto, TX") == null);
    try t.expect(parseCoordPair("95.0,10") == null); // out of range
    // "City, ST": the US state narrows the search, and Texas wins over
    // a same-named place elsewhere.
    var st = Service.init(.{ .city = "DeSoto, TX" });
    try t.expectEqualStrings(GEOCODE_URL ++ "?name=DeSoto&count=10&language=en&format=json&countryCode=US", st.poll(0).?);
    try t.expectEqualStrings("Texas", st.geo_region.slice());
    st.complete(
        \\{"results":[{"name":"De Soto","latitude":38.13,"longitude":-90.55,"country":"United States","admin1":"Missouri"},
        \\{"name":"DeSoto","latitude":32.59,"longitude":-96.86,"country":"United States","admin1":"Texas"}]}
    , 10);
    try t.expectApproxEqAbs(@as(f64, 32.59), st.lat, 1e-9);
    // "City, FR": a country code.
    var fr = Service.init(.{ .city = "Paris, fr" });
    try t.expect(std.mem.endsWith(u8, fr.poll(0).?, "&countryCode=FR"));
    // "City, Region": no filter, the region is preferred among results.
    var de = Service.init(.{ .city = "Berlin, Germany" });
    const u = de.poll(0).?;
    try t.expect(std.mem.indexOf(u8, u, "name=Berlin&count=10") != null and std.mem.indexOf(u8, u, "countryCode") == null);
    // Plain names and postal codes are searched as written.
    var z = Service.init(.{ .city = "75115" });
    try t.expect(std.mem.indexOf(u8, z.poll(0).?, "name=75115&count=1&") != null);
}

test "auto units follow the place" {
    const t = std.testing;
    try t.expectEqual(Units.fahrenheit, autoUnits("United States", ""));
    try t.expectEqual(Units.fahrenheit, autoUnits("", "America/Indiana/Indianapolis"));
    try t.expectEqual(Units.celsius, autoUnits("", "America/Toronto"));
    try t.expectEqual(Units.celsius, autoUnits("Germany", "America/Chicago")); // country wins
    try t.expectEqual(Units.fahrenheit, autoUnits("LR", ""));
    // From an IP lookup's country...
    var ip = Service.init(.{ .units_auto = true });
    _ = ip.poll(0).?;
    ip.complete("{\"city\":\"Austin\",\"country\":\"US\",\"country_name\":\"United States\",\"latitude\":30.27,\"longitude\":-97.74}", 0);
    try t.expectEqual(Units.fahrenheit, ip.units);
    // ...or, for bare coordinates, the forecast's time zone.
    var co = Service.init(.{ .latitude = 41.88, .longitude = -87.63, .units_auto = true });
    try t.expectEqual(Units.celsius, co.units); // nothing known yet
    _ = co.poll(0).?;
    co.complete(SAMPLE_FORECAST, 0); // timezone America/Chicago
    try t.expectEqual(Units.fahrenheit, co.units);
    // A fixed setting is left alone.
    var fixed = Service.init(.{ .latitude = 41.88, .longitude = -87.63, .units = .celsius });
    _ = fixed.poll(0).?;
    fixed.complete(SAMPLE_FORECAST, 0);
    try t.expectEqual(Units.celsius, fixed.units);
    // shell.json: no weather_units means auto; "C" means °C.
    try t.expect(configFromKeys(.{}, "").units_auto);
    try t.expect(!configFromKeys(.{ .weather_units = "C" }, "").units_auto);
}

test "forecast page for the place" {
    const t = std.testing;
    var out: [160]u8 = undefined;
    var s = Service.init(.{ .latitude = 41.88, .longitude = -87.63 });
    _ = s.poll(0).?;
    s.complete(SAMPLE_FORECAST, 0);
    try t.expectEqualStrings("https://forecast.weather.gov/MapClick.php?lat=41.8800&lon=-87.6300", s.forecastUrl(&out).?);
    var p = Service.init(.{ .city = "Lyon" });
    try t.expect(p.forecastUrl(&out) == null); // not located yet
    _ = p.poll(0).?;
    p.complete("{\"results\":[{\"name\":\"Lyon\",\"latitude\":45.75,\"longitude\":4.85,\"country\":\"France\"}]}", 0);
    try t.expectEqualStrings("https://www.windy.com/?45.7500,4.8500,9", p.forecastUrl(&out).?);
}

test "service: no location source at all stays quiet" {
    var s = Service.init(.{ .auto_location = false });
    try std.testing.expect(s.poll(0) == null);
    try std.testing.expectEqual(Status.no_location, s.status());
    try std.testing.expect(!s.data.loading);
}

test "compact top-bar label" {
    var s = Service.init(.{ .latitude = 41.88, .longitude = -87.63, .units = .fahrenheit });
    var out: [32]u8 = undefined;
    try std.testing.expectEqualStrings("", s.compactLabel(&out)); // no reading yet
    _ = s.poll(0).?;
    s.complete(SAMPLE_FORECAST, 0); // code 3 overcast, 4.6 °C, day
    try std.testing.expectEqualStrings("\u{E312} 40\u{00B0}F", s.compactLabel(&out));
    s.units = .celsius;
    try std.testing.expectEqualStrings("\u{E312} 5\u{00B0}C", s.compactLabel(&out));
}

test "shell.json keys and reconfigure" {
    const k = ShellJsonKeys{ .weather_latitude = 1, .weather_longitude = 2, .weather_units = "F", .weather_refresh_minutes = 0 };
    const cfg = configFromKeys(k, "");
    try std.testing.expectEqual(Units.fahrenheit, cfg.units);
    try std.testing.expectEqual(@as(i64, 60_000), cfg.refresh_ms); // clamped to 1 min
    var s = Service.init(cfg);
    _ = s.poll(0).?;
    s.complete(SAMPLE_FORECAST, 0);
    // Same place, other units: the reading stays.
    var c2 = cfg;
    c2.units = .celsius;
    s.reconfigure(c2);
    try std.testing.expect(s.data.available);
    try std.testing.expectEqual(Units.celsius, s.units);
    // Different place: start over.
    var c3 = cfg;
    c3.latitude = 3;
    s.reconfigure(c3);
    try std.testing.expect(!s.data.available);
    // Turning IP fallback off is a location change too.
    var s2 = Service.init(.{ .city = "Lyon" });
    s2.data.available = true;
    s2.reconfigure(.{ .city = "Lyon", .auto_location = false });
    try std.testing.expect(!s2.data.available and !s2.auto_location);
}

test "cache header round trip" {
    var buf: [512]u8 = undefined;
    const body = "{\"current\":{}}";
    const head = formatCacheHeader(&buf, 1763500000, "coords 41.8800,-87.6300 Chicago", 41.88, -87.63, "Chicago", "United States", body.len).?;
    var file: [1024]u8 = undefined;
    @memcpy(file[0..head.len], head);
    @memcpy(file[head.len..][0..body.len], body);
    const e = parseCache(file[0 .. head.len + body.len]).?;
    try std.testing.expectEqual(@as(i64, 1763500000), e.fetched_s);
    try std.testing.expectEqualStrings("coords 41.8800,-87.6300 Chicago", e.key);
    try std.testing.expectEqualStrings("United States", e.country);
    try std.testing.expectEqualStrings(body, e.body);
    try std.testing.expect(@abs(e.lat - 41.88) < 1e-6);
    try std.testing.expect(parseCache("not a cache") == null);
    // Truncated (writer died mid-body) and padded bodies are both rejected.
    try std.testing.expect(parseCache(file[0 .. head.len + body.len - 1]) == null);
    file[head.len + body.len] = ' ';
    try std.testing.expect(parseCache(file[0 .. head.len + body.len + 1]) == null);
    // The previous format's files are ignored, not misread.
    try std.testing.expect(parseCache("perihelion-weather 1\n1\nip\n0 0\n\n\n{}") == null);
}

test "cache file: write, adopt in a second service, reject stale/foreign" {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/tmp/perihelion-weather-test-{d}.cache", .{std.c.getpid()}) catch unreachable;
    var pz_buf: [72]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&pz_buf, "{s}", .{path}) catch unreachable;
    defer _ = libc.unlink(pz.ptr);
    const cfg = Config{ .latitude = 41.88, .longitude = -87.63, .city = "Chicago", .cache_path = path };

    // Writer: a normal fetch stores the answer.
    var a = Service.init(cfg);
    _ = a.poll(0).?;
    a.complete(SAMPLE_FORECAST, 0);
    try std.testing.expect(a.data.available);

    // Reader with the same config adopts it instead of fetching…
    var b = Service.init(cfg);
    try std.testing.expect(b.poll(0) == null);
    try std.testing.expect(b.data.available and !b.data.stale);
    try std.testing.expectEqualStrings("Chicago", b.data.city.slice());
    // …and schedules itself after the writer's next refresh.
    try std.testing.expect(b.next_due_ms > DEFAULT_REFRESH_MS);

    // A different place must not take it.
    var c = Service.init(.{ .latitude = 10, .longitude = 10, .cache_path = path });
    try std.testing.expect(c.poll(0) != null);
    try std.testing.expect(!c.data.available);

    // Units-only reconfigure keeps b's reading; a city change drops it.
    var cf = cfg;
    cf.units = .fahrenheit;
    b.reconfigure(cf);
    try std.testing.expect(b.data.available and b.units == .fahrenheit);
    cf.city = "Evanston";
    b.reconfigure(cf);
    try std.testing.expect(!b.data.available);
}

test "timezone city fallback and units" {
    var n: Name = .{};
    cityFromTimezone("America/Argentina/Buenos_Aires", &n);
    try std.testing.expectEqualStrings("Buenos Aires", n.slice());
    try std.testing.expectEqual(Units.fahrenheit, Units.parse("F").?);
    try std.testing.expectEqual(Units.celsius, Units.parse("metric").?);
    try std.testing.expectEqual(@as(i32, 0), roundi(-0.4));
}
