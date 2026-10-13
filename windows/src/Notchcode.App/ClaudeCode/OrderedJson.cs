// OrderedJson.cs
// Port of Sources/notchcode/ClaudeCode/OrderedJSON.swift.
// A small JSON parser and printer that keeps key order and the original text of strings
// and numbers, so HooksInstaller can edit %USERPROFILE%\.claude\settings.json and write back
// the same bytes for everything it did not touch. (JsonValue keeps order too, but not the
// original text of numbers and escaped strings.)

using System.Globalization;
using System.Text;

namespace Notchcode.ClaudeCode;

public enum OJKind { Object, Array, String, Number, Bool, Null }

/// One member of an OJ object. `RawKey` is the key's literal as written, quotes included.
public sealed record OJMember(string Key, OJ Value, string? RawKey = null);

/// JSON that keeps key order and the original text of strings and numbers. Immutable: an
/// edit builds a new value (Swift's enum is a value type).
public sealed class OJ
{
    public OJKind Kind { get; }
    private readonly IReadOnlyList<OJMember>? _members;
    private readonly IReadOnlyList<OJ>? _items;
    private readonly string? _text;   // the decoded string, or the number's literal
    private readonly string? _raw;    // a string's literal as written, quotes included
    private readonly bool _bool;

    private OJ(OJKind kind, IReadOnlyList<OJMember>? members = null, IReadOnlyList<OJ>? items = null,
               string? text = null, string? raw = null, bool b = false)
    {
        Kind = kind;
        _members = members;
        _items = items;
        _text = text;
        _raw = raw;
        _bool = b;
    }

    public static OJ Object(IEnumerable<OJMember> members) => new(OJKind.Object, members: members.ToList());
    public static OJ Array(IEnumerable<OJ> items) => new(OJKind.Array, items: items.ToList());
    public static OJ String(string s, string? raw = null) => new(OJKind.String, text: s, raw: raw);
    public static OJ Number(string literal) => new(OJKind.Number, text: literal);
    public static OJ Bool(bool b) => new(OJKind.Bool, b: b);
    public static readonly OJ Null = new(OJKind.Null);

    /// The members of an object; null for anything else.
    public IReadOnlyList<OJMember>? Members => _members;
    /// The items of an array; null for anything else.
    public IReadOnlyList<OJ>? Items => _items;
    /// A string's decoded text; null for anything else.
    public string? StringValue => Kind == OJKind.String ? _text : null;
    /// A number's literal; null for anything else.
    public string? NumberLiteral => Kind == OJKind.Number ? _text : null;
    public bool? BoolValue => Kind == OJKind.Bool ? _bool : null;

    /// The first member under `key` of an object; null when absent or not an object.
    public OJ? this[string key] => _members?.FirstOrDefault(m => m.Key == key)?.Value;

    /// Compact text for equality checks (decoded strings, keys in order).
    public string Canonical
    {
        get
        {
            switch (Kind)
            {
                case OJKind.Object:
                    return "{" + string.Join(",", _members!.Select(m => Quote(m.Key) + ":" + m.Value.Canonical)) + "}";
                case OJKind.Array:
                    return "[" + string.Join(",", _items!.Select(i => i.Canonical)) + "]";
                case OJKind.String: return Quote(_text!);
                case OJKind.Number: return _text!;
                case OJKind.Bool: return _bool ? "true" : "false";
                default: return "null";
            }
        }
    }

    /// Same layout as JSON.stringify(value, null, 2).
    public string Pretty(int indent = 0)
    {
        var sb = new StringBuilder();
        WritePretty(sb, indent);
        return sb.ToString();
    }

    private void WritePretty(StringBuilder sb, int indent)
    {
        string pad = new(' ', indent * 2);
        string inner = new(' ', (indent + 1) * 2);
        switch (Kind)
        {
            case OJKind.Object:
                if (_members!.Count == 0) { sb.Append("{}"); return; }
                sb.Append("{\n");
                for (int i = 0; i < _members.Count; i++)
                {
                    var m = _members[i];
                    sb.Append(inner).Append(m.RawKey ?? Quote(m.Key)).Append(": ");
                    m.Value.WritePretty(sb, indent + 1);
                    if (i < _members.Count - 1) sb.Append(',');
                    sb.Append('\n');
                }
                sb.Append(pad).Append('}');
                return;
            case OJKind.Array:
                if (_items!.Count == 0) { sb.Append("[]"); return; }
                sb.Append("[\n");
                for (int i = 0; i < _items.Count; i++)
                {
                    sb.Append(inner);
                    _items[i].WritePretty(sb, indent + 1);
                    if (i < _items.Count - 1) sb.Append(',');
                    sb.Append('\n');
                }
                sb.Append(pad).Append(']');
                return;
            case OJKind.String: sb.Append(_raw ?? Quote(_text!)); return;
            case OJKind.Number: sb.Append(_text); return;
            case OJKind.Bool: sb.Append(_bool ? "true" : "false"); return;
            default: sb.Append("null"); return;
        }
    }

    /// JSON.stringify's string escaping.
    public static string Quote(string s)
    {
        var sb = new StringBuilder(s.Length + 2);
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }

    public override string ToString() => Canonical;
}

/// Thrown for text that is not JSON. The message says what and where.
public sealed class OJParseException(string message) : Exception(message);

public sealed class OJParser
{
    private readonly byte[] _b;
    private int _i;

    private OJParser(byte[] b) { _b = b; }

    public static OJ Parse(byte[] bytes)
    {
        var p = new OJParser(bytes);
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) p._i = 3; // UTF-8 BOM
        var v = p.Value();
        p.Skip();
        if (p._i != p._b.Length) throw p.Fail("unexpected text after the value");
        return v;
    }

    public static OJ Parse(string text) => Parse(Encoding.UTF8.GetBytes(text));

    private OJParseException Fail(string why) => new($"{why} at byte {_i}");

    private void Skip()
    {
        while (_i < _b.Length && (_b[_i] == 0x20 || _b[_i] == 0x0A || _b[_i] == 0x0D || _b[_i] == 0x09)) _i++;
    }

    private OJ Value()
    {
        Skip();
        if (_i >= _b.Length) throw Fail("unexpected end");
        switch ((char)_b[_i])
        {
            case '{':
            {
                _i++;
                var members = new List<OJMember>();
                Skip();
                if (_i < _b.Length && _b[_i] == '}') { _i++; return OJ.Object(members); }
                while (true)
                {
                    Skip();
                    if (_i >= _b.Length || _b[_i] != '"') throw Fail("expected a key");
                    var (key, raw) = String();
                    Skip();
                    if (_i >= _b.Length || _b[_i] != ':') throw Fail("expected ':'");
                    _i++;
                    members.Add(new OJMember(key, Value(), raw));
                    Skip();
                    if (_i >= _b.Length) throw Fail("unexpected end");
                    if (_b[_i] == ',') { _i++; continue; }
                    if (_b[_i] == '}') { _i++; return OJ.Object(members); }
                    throw Fail("expected ',' or '}'");
                }
            }
            case '[':
            {
                _i++;
                var items = new List<OJ>();
                Skip();
                if (_i < _b.Length && _b[_i] == ']') { _i++; return OJ.Array(items); }
                while (true)
                {
                    items.Add(Value());
                    Skip();
                    if (_i >= _b.Length) throw Fail("unexpected end");
                    if (_b[_i] == ',') { _i++; continue; }
                    if (_b[_i] == ']') { _i++; return OJ.Array(items); }
                    throw Fail("expected ',' or ']'");
                }
            }
            case '"':
            {
                var (s, raw) = String();
                return OJ.String(s, raw);
            }
            case 't': Literal("true"); return OJ.Bool(true);
            case 'f': Literal("false"); return OJ.Bool(false);
            case 'n': Literal("null"); return OJ.Null;
            default:
            {
                int start = _i;
                while (_i < _b.Length && "+-0123456789.eE".IndexOf((char)_b[_i]) >= 0) _i++;
                if (_i == start) throw Fail("unexpected character");
                var text = Encoding.ASCII.GetString(_b, start, _i - start);
                if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out _)) throw Fail("bad number");
                return OJ.Number(text);
            }
        }
    }

    private void Literal(string word)
    {
        if (_i + word.Length > _b.Length) throw Fail("unexpected character");
        for (int k = 0; k < word.Length; k++)
            if (_b[_i + k] != word[k]) throw Fail("unexpected character");
        _i += word.Length;
    }

    /// Returns the decoded string and its raw literal (quotes included).
    private (string, string) String()
    {
        int start = _i;
        _i++;
        var sb = new StringBuilder();
        int chunk = _i;
        void Flush(int end) { if (end > chunk) sb.Append(Encoding.UTF8.GetString(_b, chunk, end - chunk)); }
        while (true)
        {
            if (_i >= _b.Length) throw Fail("unterminated string");
            byte c = _b[_i];
            if (c == '"')
            {
                Flush(_i);
                _i++;
                return (sb.ToString(), Encoding.UTF8.GetString(_b, start, _i - start));
            }
            if (c < 0x20) throw Fail("control character in string");
            if (c != '\\') { _i++; continue; }
            Flush(_i);
            _i++;
            if (_i >= _b.Length) throw Fail("unterminated string");
            byte e = _b[_i];
            _i++;
            switch ((char)e)
            {
                case '"': sb.Append('"'); break;
                case '\\': sb.Append('\\'); break;
                case '/': sb.Append('/'); break;
                case 'b': sb.Append('\b'); break;
                case 'f': sb.Append('\f'); break;
                case 'n': sb.Append('\n'); break;
                case 'r': sb.Append('\r'); break;
                case 't': sb.Append('\t'); break;
                case 'u':
                {
                    int code = Hex4();
                    if (code is >= 0xD800 and <= 0xDBFF && _i + 1 < _b.Length && _b[_i] == '\\' && _b[_i + 1] == 'u')
                    {
                        int save = _i;
                        _i += 2;
                        int low = Hex4();
                        if (low is >= 0xDC00 and <= 0xDFFF)
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        else
                            _i = save;
                    }
                    // A lone surrogate is not a scalar: U+FFFD, as Swift's Unicode.Scalar does.
                    if (code is >= 0xD800 and <= 0xDFFF) sb.Append('�');
                    else sb.Append(char.ConvertFromUtf32(code));
                    break;
                }
                default:
                    throw Fail("bad escape");
            }
            chunk = _i;
        }
    }

    private int Hex4()
    {
        if (_i + 4 > _b.Length
            || !int.TryParse(Encoding.ASCII.GetString(_b, _i, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out var v))
            throw Fail("bad \\u escape");
        _i += 4;
        return v;
    }
}
