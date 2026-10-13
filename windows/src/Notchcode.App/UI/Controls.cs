// Controls.cs
// Port of Sources/notchcode/UI/Controls.swift: the small controls the tools share: segmented
// pills (Settings, the Files preview), the small switch and the keycap stepper (Settings),
// the small pill (Settings, Files), the tree toggle pill (Files, Git, Changes) and the small
// tag (Sessions, the Git branch picker). SwiftUI bindings become a current value plus a
// change callback; the control redraws itself and calls back, the caller writes the state.

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Notchcode.UI;

/// A picker as a row of pills in a capsule track. `Selection` is the current value;
/// `changed` is called with the value the owner picked.
public sealed class SegmentedPills<T> : Border where T : notnull
{
    private readonly IReadOnlyList<(T Value, string Title)> options;
    private readonly Action<T> changed;
    private readonly StackPanel row = new() { Orientation = Orientation.Horizontal };
    private T selection;

    public SegmentedPills(T selection, IReadOnlyList<(T Value, string Title)> options, Action<T> changed)
    {
        this.selection = selection;
        this.options = options;
        this.changed = changed;
        Padding = new Thickness(Theme.Size.PickerInset);
        Background = Theme.Brushes.PickerTrack;
        Height = Theme.Size.PickerHeight;
        CornerRadius = new CornerRadius(Theme.Size.PickerHeight / 2);
        VerticalAlignment = VerticalAlignment.Center;
        Child = row;
        Build();
    }

    public T Selection
    {
        get => selection;
        set
        {
            if (EqualityComparer<T>.Default.Equals(selection, value)) return;
            selection = value;
            Build();
        }
    }

    private void Build()
    {
        row.Children.Clear();
        double height = Theme.Size.PickerHeight - 2 * Theme.Size.PickerInset;
        foreach (var (value, title) in options)
        {
            bool selected = EqualityComparer<T>.Default.Equals(value, selection);
            var pill = new Border
            {
                Child = Ui.Text(title, Theme.Fonts.CaptionMedium, selected ? Theme.Brushes.Ink : Theme.Brushes.InkSecondary).Fixed(),
                Padding = new Thickness(Theme.Size.PickerHPadding, 0, Theme.Size.PickerHPadding, 0),
                Height = height,
                CornerRadius = new CornerRadius(height / 2),
                Background = selected ? Theme.Brushes.PickerSelected : Theme.Brushes.HitTarget,
            };
            var picked = value;
            pill.OnTap(() =>
            {
                Selection = picked;
                changed(picked);
            });
            row.Children.Add(pill);
        }
    }
}

/// A small on/off switch: green track with the knob right when on.
public sealed class SmallSwitch : Grid
{
    private readonly Border track;
    private readonly Ellipse knob;
    private readonly Action<bool> changed;
    private bool isOn;

    public SmallSwitch(bool isOn, Action<bool> changed)
    {
        this.changed = changed;
        Width = Theme.Size.SwitchWidth;
        Height = Theme.Size.SwitchHeight;
        VerticalAlignment = VerticalAlignment.Center;
        track = Ui.Capsule(Theme.Brushes.SwitchOff, Theme.Size.SwitchHeight);
        double knobSize = Theme.Size.SwitchHeight - 2 * Theme.Size.SwitchKnobInset;
        knob = new Ellipse
        {
            Width = knobSize,
            Height = knobSize,
            Fill = Theme.Brushes.SwitchKnob,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(Theme.Size.SwitchKnobInset, 0, 0, 0),
        };
        Children.Add(track);
        Children.Add(knob);
        this.isOn = !isOn;
        SetOn(isOn, animated: false);
        this.OnTap(() =>
        {
            SetOn(!this.isOn, animated: true);
            this.changed(this.isOn);
        });
    }

    public bool IsOn
    {
        get => isOn;
        set => SetOn(value, animated: true);
    }

    private void SetOn(bool value, bool animated)
    {
        if (isOn == value) return;
        isOn = value;
        track.Background = value ? Theme.Brushes.SwitchOn : Theme.Brushes.SwitchOff;
        double travel = Theme.Size.SwitchWidth - Theme.Size.SwitchHeight;
        var translate = Transitions.Translate(knob);
        if (animated) Transitions.Animate(translate, TranslateTransform.XProperty, Theme.Motion.Tap, value ? travel : 0);
        else Transitions.Snap(translate, TranslateTransform.XProperty, value ? travel : 0);
    }
}

/// − value + with keycap buttons. `changed` is called with the stepped value.
public sealed class KeycapStepper : HStack
{
    public KeycapStepper(double value, (double Min, double Max) range, double step, Func<double, string> text,
        Action<double> changed, bool enabled = true)
    {
        Spacing = Theme.Size.SpaceS;
        var minus = new Keycap(Theme.Glyphs.Minus);
        var plus = new Keycap(Theme.Keys.Plus);
        var label = Ui.Text(text(value), Theme.Fonts.CaptionMedium, Theme.Brushes.Ink).Fixed();
        var box = new Border { Child = label, Width = Theme.Size.StepperValueWidth };
        label.HorizontalAlignment = HorizontalAlignment.Center;
        double current = value;
        void Refresh()
        {
            label.Text = text(current);
            minus.IsHitTestVisible = enabled && current > range.Min;
            plus.IsHitTestVisible = enabled && current < range.Max;
        }
        minus.OnTap(() => { current = Math.Max(range.Min, current - step); Refresh(); changed(current); });
        plus.OnTap(() => { current = Math.Min(range.Max, current + step); Refresh(); changed(current); });
        Children.Add(minus);
        Children.Add(box);
        Children.Add(plus);
        Opacity = enabled ? 1 : Theme.Opacity.Disabled;
        Refresh();
    }
}

/// `SmallPillStyle`: a compact capsule button, white when primary, ghost otherwise, with the
/// strip segments' press and fill behaviour. `label` is a string or any element.
public sealed class SmallPill : SegmentButton
{
    public SmallPill(object label, Action action, bool primary = false)
        : base(Build(label, primary), primary ? Theme.Brushes.PrimaryFill : Theme.Brushes.GhostFill, capsule: true, click: action)
    {
        Height = Theme.Size.BackPillHeight;
        VerticalAlignment = VerticalAlignment.Center;
    }

    private static UIElement Build(object label, bool primary)
    {
        var brush = primary ? Theme.Brushes.PrimaryText : Theme.Brushes.Ink;
        UIElement content = label as UIElement ?? Ui.Text(label.ToString() ?? "", Theme.Fonts.CaptionMedium, brush).Fixed();
        if (content is FrameworkElement fe)
        {
            fe.Margin = new Thickness(Theme.Size.BackPillHPadding, 0, Theme.Size.BackPillHPadding, 0);
            fe.VerticalAlignment = VerticalAlignment.Center;
        }
        return content;
    }
}

/// The sidebar pill and its Ctrl B keycap. Disabled (dimmed) with no file open. The Git tool
/// hides its file list with it.
public sealed class TreeTogglePill : HStack
{
    public TreeTogglePill(bool collapsed, bool enabled, Action action, string subject = "file tree")
    {
        Spacing = Theme.Size.SpaceS;
        var glyph = Theme.Symbols.Sidebar.ToPath(Theme.Fonts.TinySize, Theme.Brushes.Ink);
        var pill = new SmallPill(glyph, action) { Enabled = enabled };
        pill.Help(collapsed ? "Show the " + subject : "Hide the " + subject);
        Children.Add(pill);
        Children.Add(new InlineKeycap(Theme.Keys.ToggleTree));
        Opacity = enabled ? 1 : Theme.Opacity.Disabled;
    }
}

/// A small capsule: "Showing", "newest", or the permission mode ("bypass" in clay).
public sealed class SmallTag : Border
{
    public SmallTag(string text, Brush? brush = null)
    {
        Child = Boxes.CapsuleTag(Ui.Text(text, Theme.Fonts.Caption, brush ?? Theme.Brushes.InkTertiary).Fixed());
        VerticalAlignment = VerticalAlignment.Center;
    }
}
