// JsonValue.cs
// Port of the JSONValue enum at the end of Sources/notchcode/Core/Contract.swift.
// A small dynamic JSON type so raw hook payloads survive decoding untouched. Object key
// order is kept as read, so a payload round-trips byte for byte in the order it arrived.
// Linked into the hook project: no WPF types here.

using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Notchcode.Core;

/// The JSON value kinds, as the Swift enum's cases.
public enum JsonValueKind { String, Number, Bool, Object, Array, Null }

/// A small dynamic JSON type so raw hook payloads survive decoding untouched.
[JsonConverter(typeof(JsonValueConverter))]
public sealed class JsonValue : IEquatable<JsonValue>
{
    public JsonValueKind Kind { get; }
    private readonly string? _string;
    private readonly double _number;
    private readonly bool _bool;
    private readonly List<KeyValuePair<string, JsonValue>>? _object;
    private readonly List<JsonValue>? _array;

    private JsonValue(JsonValueKind kind, string? s = null, double n = 0, bool b = false,
                      List<KeyValuePair<string, JsonValue>>? o = null, List<JsonValue>? a = null)
    {
        Kind = kind;
        _string = s;
        _number = n;
        _bool = b;
        _object = o;
        _array = a;
    }

    public static readonly JsonValue Null = new(JsonValueKind.Null);
    public static readonly JsonValue True = new(JsonValueKind.Bool, b: true);
    public static readonly JsonValue False = new(JsonValueKind.Bool, b: false);

    public static JsonValue String(string value) => new(JsonValueKind.String, s: value);
    public static JsonValue Number(double value) => new(JsonValueKind.Number, n: value);
    public static JsonValue Bool(bool value) => value ? True : False;

    /// An object in the given key order. A repeated key keeps its first position and its last value.
    public static JsonValue Object(IEnumerable<KeyValuePair<string, JsonValue>> members)
    {
        var list = new List<KeyValuePair<string, JsonValue>>();
        foreach (var kv in members) AddOrReplace(list, kv.Key, kv.Value);
        return new(JsonValueKind.Object, o: list);
    }

    public static JsonValue Object(params (string Key, JsonValue Value)[] members)
        => Object(members.Select(m => new KeyValuePair<string, JsonValue>(m.Key, m.Value)));

    public static JsonValue Array(IEnumerable<JsonValue> items) => new(JsonValueKind.Array, a: items.ToList());
    public static JsonValue Array(params JsonValue[] items) => new(JsonValueKind.Array, a: items.ToList());

    private static void AddOrReplace(List<KeyValuePair<string, JsonValue>> list, string key, JsonValue value)
    {
        for (int i = 0; i < list.Count; i++)
        {
            if (list[i].Key == key) { list[i] = new(key, value); return; }
        }
        list.Add(new(key, value));
    }

    // MARK: - Accessors

    /// The member under `key`; null when this is not an object or has no such key.
    public JsonValue? this[string key]
    {
        get
        {
            if (_object is null) return null;
            foreach (var kv in _object) if (kv.Key == key) return kv.Value;
            return null;
        }
    }

    /// The array element at `index`; null when this is not an array or the index is out of range.
    public JsonValue? this[int index]
        => _array is not null && index >= 0 && index < _array.Count ? _array[index] : null;

    public bool IsNull => Kind == JsonValueKind.Null;
    public string? StringValue => Kind == JsonValueKind.String ? _string : null;
    public double? DoubleValue => Kind == JsonValueKind.Number ? _number : null;

    /// Null for a number no int can hold; a fraction is cut toward zero.
    public int? IntValue
    {
        get
        {
            if (DoubleValue is not double d || double.IsNaN(d) || double.IsInfinity(d)) return null;
            var t = Math.Truncate(d);
            return t >= int.MinValue && t <= int.MaxValue ? (int)t : null;
        }
    }

    /// As `IntValue`, for 64-bit values (Swift's Int is 64 bits: millisecond durations, large token counts).
    public long? LongValue
    {
        get
        {
            if (DoubleValue is not double d || double.IsNaN(d) || double.IsInfinity(d)) return null;
            var t = Math.Truncate(d);
            // 2^63 itself is not representable as long; the bound is exclusive.
            return t >= -9.2233720368547758E+18 && t < 9.2233720368547758E+18 ? (long)t : null;
        }
    }

    public bool? BoolValue => Kind == JsonValueKind.Bool ? _bool : null;
    public IReadOnlyList<JsonValue>? ArrayValue => _array;
    /// The members in their original order.
    public IReadOnlyList<KeyValuePair<string, JsonValue>>? ObjectValue => _object;

    // MARK: - Equality (objects compare as dictionaries: order does not matter, as in Swift)

    public bool Equals(JsonValue? other)
    {
        if (other is null) return false;
        if (ReferenceEquals(this, other)) return true;
        if (Kind != other.Kind) return false;
        switch (Kind)
        {
            case JsonValueKind.Null: return true;
            case JsonValueKind.Bool: return _bool == other._bool;
            case JsonValueKind.Number: return _number.Equals(other._number);
            case JsonValueKind.String: return _string == other._string;
            case JsonValueKind.Array: return _array!.SequenceEqual(other._array!);
            case JsonValueKind.Object:
                if (_object!.Count != other._object!.Count) return false;
                foreach (var kv in _object)
                {
                    var o = other[kv.Key];
                    if (o is null || !kv.Value.Equals(o)) return false;
                }
                return true;
        }
        return false;
    }

    public override bool Equals(object? obj) => obj is JsonValue v && Equals(v);

    public override int GetHashCode()
    {
        switch (Kind)
        {
            case JsonValueKind.String: return HashCode.Combine(Kind, _string);
            case JsonValueKind.Number: return HashCode.Combine(Kind, _number);
            case JsonValueKind.Bool: return HashCode.Combine(Kind, _bool);
            case JsonValueKind.Array: return HashCode.Combine(Kind, _array!.Count);
            case JsonValueKind.Object:
                // Order-independent.
                int h = 0;
                foreach (var kv in _object!) h ^= HashCode.Combine(kv.Key, kv.Value);
                return HashCode.Combine(Kind, h);
            default: return (int)Kind;
        }
    }

    public static bool operator ==(JsonValue? a, JsonValue? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(JsonValue? a, JsonValue? b) => !(a == b);

    // MARK: - Reading and writing

    public static JsonValue Parse(string json)
    {
        var reader = new Utf8JsonReader(Encoding.UTF8.GetBytes(json), new JsonReaderOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true });
        reader.Read();
        return Read(ref reader);
    }

    /// Reads the value at the reader's current token.
    public static JsonValue Read(ref Utf8JsonReader reader)
    {
        switch (reader.TokenType)
        {
            case JsonTokenType.Null: return Null;
            case JsonTokenType.True: return True;
            case JsonTokenType.False: return False;
            case JsonTokenType.Number: return Number(reader.GetDouble());
            case JsonTokenType.String: return String(reader.GetString() ?? "");
            case JsonTokenType.StartArray:
            {
                var items = new List<JsonValue>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                    items.Add(Read(ref reader));
                return new(JsonValueKind.Array, a: items);
            }
            case JsonTokenType.StartObject:
            {
                var members = new List<KeyValuePair<string, JsonValue>>();
                while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
                {
                    var key = reader.GetString() ?? "";
                    reader.Read();
                    AddOrReplace(members, key, Read(ref reader));
                }
                return new(JsonValueKind.Object, o: members);
            }
            default:
                throw new JsonException("Unsupported JSON value");
        }
    }

    /// Writes through a Utf8JsonWriter, keys in their stored order (or sorted, as Swift's `.sortedKeys`).
    public void WriteTo(Utf8JsonWriter writer, bool sortKeys = false)
    {
        switch (Kind)
        {
            case JsonValueKind.Null: writer.WriteNullValue(); break;
            case JsonValueKind.Bool: writer.WriteBooleanValue(_bool); break;
            case JsonValueKind.Number: writer.WriteNumberValue(_number); break;
            case JsonValueKind.String: writer.WriteStringValue(_string); break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in _array!) item.WriteTo(writer, sortKeys);
                writer.WriteEndArray();
                break;
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var kv in sortKeys ? SortedMembers() : _object!)
                {
                    writer.WritePropertyName(kv.Key);
                    kv.Value.WriteTo(writer, sortKeys);
                }
                writer.WriteEndObject();
                break;
        }
    }

    private IEnumerable<KeyValuePair<string, JsonValue>> SortedMembers()
        => _object!.OrderBy(kv => kv.Key, StringComparer.Ordinal);

    /// Compact JSON the way Swift's JSONEncoder writes it with `.sortedKeys` and
    /// `.withoutEscapingSlashes`: only `"`, `\` and control characters escaped, non-ASCII as is.
    /// Used for the reply line, which must match the macOS app byte for byte.
    public string ToSwiftJson(bool sortKeys = true)
    {
        var sb = new StringBuilder();
        AppendSwiftJson(sb, sortKeys);
        return sb.ToString();
    }

    internal void AppendSwiftJson(StringBuilder sb, bool sortKeys)
    {
        switch (Kind)
        {
            case JsonValueKind.Null: sb.Append("null"); break;
            case JsonValueKind.Bool: sb.Append(_bool ? "true" : "false"); break;
            case JsonValueKind.Number: sb.Append(FormatNumber(_number)); break;
            case JsonValueKind.String: AppendSwiftString(sb, _string!); break;
            case JsonValueKind.Array:
                sb.Append('[');
                for (int i = 0; i < _array!.Count; i++)
                {
                    if (i > 0) sb.Append(',');
                    _array[i].AppendSwiftJson(sb, sortKeys);
                }
                sb.Append(']');
                break;
            case JsonValueKind.Object:
                sb.Append('{');
                bool first = true;
                foreach (var kv in sortKeys ? SortedMembers() : _object!)
                {
                    if (!first) sb.Append(',');
                    first = false;
                    AppendSwiftString(sb, kv.Key);
                    sb.Append(':');
                    kv.Value.AppendSwiftJson(sb, sortKeys);
                }
                sb.Append('}');
                break;
        }
    }

    /// An integral double prints without a fraction ("1", not "1.0"), as JSONEncoder does.
    internal static string FormatNumber(double n)
    {
        if (Math.Abs(n) < 1e15 && n == Math.Truncate(n)) return ((long)n).ToString(CultureInfo.InvariantCulture);
        return n.ToString("R", CultureInfo.InvariantCulture);
    }

    internal static void AppendSwiftString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\b': sb.Append("\\b"); break;
                case '\f': sb.Append("\\f"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }

    public override string ToString() => ToSwiftJson(sortKeys: false);
}

/// System.Text.Json converter for JsonValue: keeps key order, maps JSON null to `JsonValue.Null`.
public sealed class JsonValueConverter : JsonConverter<JsonValue>
{
    public override bool HandleNull => true;

    public override JsonValue Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => JsonValue.Read(ref reader);

    public override void Write(Utf8JsonWriter writer, JsonValue? value, JsonSerializerOptions options)
    {
        if (value is null) writer.WriteNullValue();
        else value.WriteTo(writer);
    }
}
