const std = @import("std");

const log = std.log.scoped(.fs_utils);

/// Match a relative path against a gitignore-style glob pattern.
///
/// Semantics (a practical subset of gitignore):
///   - `*`  matches any run of characters except `/`
///   - `**` matches any run of characters including `/` (spans directories)
///   - `?`  matches any single character except `/`
///   - `[abc]` / `[a-z]` character classes (with optional leading `!` negation)
///   - A leading `/` anchors the pattern to the root of `path`.
///   - A pattern containing no `/` (ignoring a trailing one) matches against the
///     basename at any depth (e.g. `.env` matches `src/config/.env`).
///   - A trailing `/` marks a directory pattern; it matches the directory itself
///     and anything nested beneath it.
///
/// `path` is expected to use `/` separators and no leading `/`.
pub fn matchGlob(path: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return false;

    var pat = pattern;

    // Trailing slash => directory pattern. Match the dir and everything under it.
    var dir_only = false;
    if (pat.len > 1 and pat[pat.len - 1] == '/') {
        dir_only = true;
        pat = pat[0 .. pat.len - 1];
    }

    // Leading slash anchors to root.
    var anchored = false;
    if (pat.len > 0 and pat[0] == '/') {
        anchored = true;
        pat = pat[1..];
    }
    if (pat.len == 0) return false;

    // Does the pattern reference a path separator? (determines basename fallback)
    const has_slash = std.mem.indexOfScalar(u8, pat, '/') != null;

    if (dir_only) {
        // Match "pat" as a prefix path component, then anything under it.
        if (globMatchPrefix(path, pat, anchored, has_slash)) return true;
        return false;
    }

    // Anchored or contains a slash: match against the full path from root.
    if (anchored or has_slash) {
        return globMatch(path, pat);
    }

    // Unanchored, no slash: match against the full path OR the basename at any depth.
    if (globMatch(path, pat)) return true;
    const base = std.fs.path.basename(path);
    return globMatch(base, pat);
}

/// For directory patterns: true if `pat` matches a leading portion of `path`
/// on component boundaries (so `build/` matches `build` and `build/x/y`).
fn globMatchPrefix(path: []const u8, pat: []const u8, anchored: bool, has_slash: bool) bool {
    // Try matching pat against every component-boundary prefix of path.
    // If not anchored and the pattern has no slash, we may also start matching
    // at any interior component (basename-at-any-depth semantics).
    var start: usize = 0;
    while (true) {
        const sub = path[start..];
        // Whole remaining path matches the pattern.
        if (globMatch(sub, pat)) return true;
        // pattern matches a component prefix followed by "/..."
        var i: usize = 0;
        while (i < sub.len) : (i += 1) {
            if (sub[i] == '/') {
                if (globMatch(sub[0..i], pat)) return true;
            }
        }
        if (anchored or has_slash) return false;
        // Advance to the next component start for basename-at-any-depth.
        const next = std.mem.indexOfScalarPos(u8, path, start, '/') orelse return false;
        start = next + 1;
        if (start >= path.len) return false;
    }
}

/// Core glob matcher. `*` does not cross `/`, `**` does. `?` matches one non-`/`.
fn globMatch(str: []const u8, pat: []const u8) bool {
    var si: usize = 0;
    var pi: usize = 0;

    // Backtracking state for a single `*` (star) that does not cross `/`.
    var star_pi: ?usize = null;
    var star_si: usize = 0;

    // Backtracking state for `**` (globstar) that crosses `/`.
    var dstar_pi: ?usize = null;
    var dstar_si: usize = 0;

    while (si < str.len) {
        if (pi < pat.len) {
            const c = pat[pi];
            switch (c) {
                '*' => {
                    if (pi + 1 < pat.len and pat[pi + 1] == '*') {
                        // Globstar: consume "**" (and an optional following '/').
                        var np = pi + 2;
                        if (np < pat.len and pat[np] == '/') np += 1;
                        dstar_pi = np;
                        dstar_si = si;
                        // Also allow globstar to match zero characters.
                        pi = np;
                        // Clear single-star state; globstar supersedes here.
                        star_pi = null;
                        continue;
                    } else {
                        star_pi = pi + 1;
                        star_si = si;
                        pi += 1;
                        continue;
                    }
                },
                '?' => {
                    if (str[si] != '/') {
                        si += 1;
                        pi += 1;
                        continue;
                    }
                },
                '[' => {
                    if (matchClass(str[si], pat, &pi)) {
                        si += 1;
                        continue;
                    }
                },
                else => {
                    if (str[si] == c) {
                        si += 1;
                        pi += 1;
                        continue;
                    }
                },
            }
        }

        // Mismatch: try to backtrack.
        if (star_pi) |sp| {
            // Single star: extend match but not across '/'.
            if (str[star_si] != '/') {
                pi = sp;
                star_si += 1;
                si = star_si;
                continue;
            } else {
                star_pi = null;
            }
        }
        if (dstar_pi) |dp| {
            // Globstar: extend match, may cross '/'.
            pi = dp;
            dstar_si += 1;
            si = dstar_si;
            continue;
        }
        return false;
    }

    // Consume trailing '*' / '**' / '/**' in the pattern.
    while (pi < pat.len) {
        if (pat[pi] == '*') {
            pi += 1;
        } else if (pat[pi] == '/' and pi + 1 < pat.len and pat[pi + 1] == '*') {
            pi += 1;
        } else {
            break;
        }
    }

    return pi == pat.len;
}

/// Match a character class `[...]` starting at pat[*pi] == '['.
/// On success advances *pi past the closing ']' and returns whether `ch` matched.
/// If the class is malformed (no closing ']'), treats '[' literally.
fn matchClass(ch: u8, pat: []const u8, pi: *usize) bool {
    var i = pi.* + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }

    // Find the closing ']'. A ']' immediately after '[' (or '[!' ) is literal.
    var matched = false;
    var first = true;
    var closed = false;
    var j = i;
    while (j < pat.len) {
        const cj = pat[j];
        if (cj == ']' and !first) {
            closed = true;
            break;
        }
        first = false;
        // Range: a-z
        if (j + 2 < pat.len and pat[j + 1] == '-' and pat[j + 2] != ']') {
            const lo = cj;
            const hi = pat[j + 2];
            if (ch >= lo and ch <= hi) matched = true;
            j += 3;
        } else {
            if (ch == cj) matched = true;
            j += 1;
        }
    }

    if (!closed) {
        // Malformed class: treat '[' as a literal character.
        if (ch == '[') {
            pi.* += 1;
            return true;
        }
        return false;
    }

    pi.* = j + 1; // advance past ']'
    return matched != negate;
}

/// Calculate relative path from `from` to `to`
/// E.g., relativePath("/a/b/c/file", "/a/x/y/target") returns "../../x/y/target"
pub fn relativePath(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    // Get directory of 'from' (we want path relative to the directory, not the file)
    const from_dir = std.fs.path.dirname(from) orelse ".";

    // Split paths into components
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);

    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);

    var from_iter = std.mem.splitScalar(u8, from_dir, '/');
    while (from_iter.next()) |part| {
        if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try from_parts.append(allocator, part);
        }
    }

    var to_iter = std.mem.splitScalar(u8, to, '/');
    while (to_iter.next()) |part| {
        if (part.len > 0 and !std.mem.eql(u8, part, ".")) {
            try to_parts.append(allocator, part);
        }
    }

    // Find common prefix length
    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len) {
        if (!std.mem.eql(u8, from_parts.items[common], to_parts.items[common])) {
            break;
        }
        common += 1;
    }

    // Build relative path
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Add ".." for each remaining component in from_dir
    for (0..(from_parts.items.len - common)) |_| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, "..");
    }

    // Add remaining components from 'to'
    for (to_parts.items[common..]) |part| {
        if (result.items.len > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    if (result.items.len == 0) {
        try result.append(allocator, '.');
    }

    return result.toOwnedSlice(allocator);
}
