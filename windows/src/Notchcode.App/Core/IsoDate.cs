// IsoDate.cs
// Port of Sources/notchcode/Core/ISODate.swift.
// Parses the ISO 8601 timestamps Claude Code writes in transcripts and in its usage cache,
// with and without fractional seconds. Results are UTC DateTimes.

using System.Globalization;

namespace Notchcode.Core;

public static class IsoDate
{
    private static readonly string[] Formats =
    [
        "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK",
        "yyyy-MM-dd'T'HH:mm:ssK",
    ];

    /// An internet date-time ("2026-10-12T09:14:03.512Z", "2026-10-12T09:14:03+02:00"); null otherwise.
    /// A time zone is required, as ISO8601DateFormatter's `.withInternetDateTime` requires it.
    public static DateTime? Parse(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        // More than 7 fractional digits: .NET's 'F' stops at 7, so cut the rest.
        var text = TrimFraction(s);
        if (DateTimeOffset.TryParseExact(text, Formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dto)
            && HasZone(text))
            return dto.UtcDateTime;
        return null;
    }

    public static DateTime? Parse(JsonValue? value) => Parse(value?.StringValue);

    public static DateTime? Parse(object? any) => any switch
    {
        string s => Parse(s),
        JsonValue v => Parse(v.StringValue),
        _ => null,
    };

    private static bool HasZone(string s)
    {
        if (s.EndsWith('Z') || s.EndsWith('z')) return true;
        int t = s.IndexOf('T');
        return t > 0 && (s.IndexOf('+', t) > 0 || s.IndexOf('-', t) > 0);
    }

    private static string TrimFraction(string s)
    {
        int dot = s.IndexOf('.');
        if (dot < 0) return s;
        int end = dot + 1;
        while (end < s.Length && char.IsAsciiDigit(s[end])) end++;
        int digits = end - dot - 1;
        return digits > 7 ? s[..(dot + 8)] + s[end..] : s;
    }
}
