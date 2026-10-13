// Keycaps.cs
// Keycaps: the boxed key, the inline keycap in running text, and the footer's key hints.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Notchcode.UI;

// MARK: - Keycap

/// A key's label in a small rounded box: `Theme.Fonts.keycap`, the quiet fill and a
/// hairline edge; `OnLight` for a keycap on the white primary pill (dark fill, no edge).
public class Keycap : Border
{
    private readonly TextBlock text = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        TextAlignment = TextAlignment.Center,
    };

    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(Keycap), new PropertyMetadata("", (d, e) => ((Keycap)d).SetText((string)e.NewValue)));

    public static readonly DependencyProperty OnLightProperty = DependencyProperty.Register(
        nameof(OnLight), typeof(bool), typeof(Keycap), new PropertyMetadata(false, (d, _) => ((Keycap)d).Restyle()));

    public string Label
    {
        get => (string)GetValue(LabelProperty);
        set => SetValue(LabelProperty, value);
    }

    public bool OnLight
    {
        get => (bool)GetValue(OnLightProperty);
        set => SetValue(OnLightProperty, value);
    }

    public Keycap() : this("") { }

    public Keycap(string label, bool onLight = false)
    {
        Theme.Fonts.Keycap.Apply(text);
        Child = text;
        Padding = new Thickness(Theme.Size.KeycapHPadding, 0, Theme.Size.KeycapHPadding, 0);
        MinWidth = Theme.Size.KeycapMin;
        MinHeight = Theme.Size.KeycapMin;
        CornerRadius = new CornerRadius(Theme.Radius.Keycap);
        VerticalAlignment = VerticalAlignment.Center;
        SnapsToDevicePixels = true;
        Label = label;
        OnLight = onLight;
        Restyle();
    }

    /// The label as runs: letters in the keycap font, key symbols (⏎ ⌫ ⇥ ↑↓) in the symbol
    /// font, so "Alt ⏎" reads as the Mac's "⌥ ⏎" does instead of a faint fallback glyph.
    private void SetText(string label)
    {
        text.Inlines.Clear();
        int start = 0;
        while (start < label.Length)
        {
            bool symbol = Theme.Fonts.IsKeySymbol(label[start]);
            int end = start + 1;
            while (end < label.Length && Theme.Fonts.IsKeySymbol(label[end]) == symbol) end++;
            var run = new System.Windows.Documents.Run(label[start..end]);
            if (symbol) Theme.Fonts.KeycapSymbol.Apply(run);
            text.Inlines.Add(run);
            start = end;
        }
    }

    private void Restyle()
    {
        text.Foreground = OnLight ? Theme.Brushes.KeycapTextOnLight : Theme.Brushes.InkSecondary;
        Background = OnLight ? Theme.Brushes.KeycapFillOnLight : Theme.Brushes.KeycapFill;
        // SwiftUI's strokeBorder draws inside the box, as a WPF Border does.
        BorderBrush = OnLight ? null : Theme.Brushes.Hairline;
        BorderThickness = new Thickness(OnLight ? 0 : Theme.Size.Hairline);
    }
}

/// A keycap beside a button inside the card; hidden by the Settings switch (the inherited
/// `InlineKeycaps` property, set once on the card's well). The footer and the attention
/// row use Keycap directly.
public sealed class InlineKeycap : Keycap
{
    /// Whether `InlineKeycap`s show; set once on the card's well from Settings, inherited.
    public static readonly DependencyProperty InlineKeycapsProperty = DependencyProperty.RegisterAttached(
        "InlineKeycaps", typeof(bool), typeof(InlineKeycap),
        new FrameworkPropertyMetadata(true, FrameworkPropertyMetadataOptions.Inherits, OnInlineKeycapsChanged));

    public static bool GetInlineKeycaps(DependencyObject d) => (bool)d.GetValue(InlineKeycapsProperty);
    public static void SetInlineKeycaps(DependencyObject d, bool value) => d.SetValue(InlineKeycapsProperty, value);

    public InlineKeycap() : this("") { }

    public InlineKeycap(string label) : base(label)
    {
        Visibility = GetInlineKeycaps(this) ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void OnInlineKeycapsChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is InlineKeycap keycap)
            keycap.Visibility = (bool)e.NewValue ? Visibility.Visible : Visibility.Collapsed;
    }
}

/// One keycap and what it does, for the card's footer.
public readonly record struct KeyHint(string Key, string Label);

/// "⏎ open  Y copy path:line": keycaps with their tertiary labels, never truncated.
public sealed class KeyHints : StackPanel
{
    private IReadOnlyList<KeyHint> hints = Array.Empty<KeyHint>();

    public KeyHints() : this(Array.Empty<KeyHint>()) { }

    public KeyHints(IEnumerable<KeyHint> hints)
    {
        Orientation = Orientation.Horizontal;
        VerticalAlignment = VerticalAlignment.Center;
        Hints = hints.ToArray();
    }

    public IReadOnlyList<KeyHint> Hints
    {
        get => hints;
        set
        {
            hints = value;
            Children.Clear();
            foreach (var hint in hints)
            {
                // HStack(spacing: spaceS) between every keycap and label.
                var keycap = new Keycap(hint.Key) { Margin = new Thickness(Children.Count == 0 ? 0 : Theme.Size.SpaceS, 0, 0, 0) };
                Children.Add(keycap);
                var label = new TextBlock
                {
                    Text = hint.Label,
                    Foreground = Theme.Brushes.InkTertiary,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextWrapping = TextWrapping.NoWrap,
                    Margin = new Thickness(Theme.Size.SpaceS, 0, 0, 0),
                };
                Theme.Fonts.Caption.Apply(label);
                Children.Add(label);
            }
        }
    }
}
