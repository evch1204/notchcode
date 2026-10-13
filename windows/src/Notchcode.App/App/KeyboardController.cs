// KeyboardController.cs
// Port of Sources/notchcode/App/KeyboardController.swift: decodes the window's key presses
// into `NotchKey` and swallows the ones the app used. ⌘ is Ctrl and ⌥ is Alt on Windows:
// Ctrl , settings, Ctrl Q quit, Ctrl B the tree, Ctrl ⏎ submit, Alt ⏎ teleport. The window
// only has the keys while the card is open; `AppState.HandleKey` checks the mode itself.

using System.Windows;
using System.Windows.Input;
using Notchcode.State;

namespace Notchcode.App;

public sealed class KeyboardController
{
    private readonly UIElement target;
    private readonly Func<NotchKey, bool> handler;
    private bool installed;

    public KeyboardController(UIElement target, Func<NotchKey, bool> handler)
    {
        this.target = target;
        this.handler = handler;
    }

    public void Install()
    {
        if (installed) return;
        installed = true;
        target.PreviewKeyDown += OnPreviewKeyDown;
    }

    public void Remove()
    {
        if (!installed) return;
        installed = false;
        target.PreviewKeyDown -= OnPreviewKeyDown;
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        // Alt combinations arrive as Key.System with the real key in SystemKey.
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (Decode(key, Keyboard.Modifiers) is not { } notchKey) return;
        if (handler(notchKey)) e.Handled = true;
    }

    /// The key a press means, or null when the card has no use for it.
    public static NotchKey? Decode(Key key, ModifierKeys modifiers)
    {
        bool ctrl = modifiers.HasFlag(ModifierKeys.Control);
        bool alt = modifiers.HasFlag(ModifierKeys.Alt);
        bool shift = modifiers.HasFlag(ModifierKeys.Shift);
        if (ctrl && key == Key.OemComma) return NotchKey.Settings;
        if (ctrl && key == Key.Q) return NotchKey.Quit;
        if (ctrl && key == Key.B) return NotchKey.ToggleTree;
        if (ctrl && key == Key.Enter) return NotchKey.Submit;
        if (ctrl || modifiers.HasFlag(ModifierKeys.Windows)) return null;

        switch (key)
        {
            case Key.Enter: return alt ? NotchKey.Teleport : NotchKey.Primary;
            case Key.Back:
            case Key.Delete: return NotchKey.Deny;
            case Key.Escape: return NotchKey.Escape;
            case Key.Space: return alt || shift ? null : NotchKey.Toggle;
            case Key.Tab: return shift ? NotchKey.PreviousTab : NotchKey.NextTab;
            case Key.Up: return NotchKey.Up;
            case Key.Down: return NotchKey.Down;
            case Key.Left: return NotchKey.Left;
            case Key.Right: return NotchKey.Right;
            case Key.D1: case Key.NumPad1: return NotchKey.Number(1);
            case Key.D2: case Key.NumPad2: return NotchKey.Number(2);
            case Key.D3: case Key.NumPad3: return NotchKey.Number(3);
            case Key.D4: case Key.NumPad4: return NotchKey.Number(4);
            case Key.D5: case Key.NumPad5: return NotchKey.Number(5);
        }
        // Letters by their key, as `charactersIgnoringModifiers` (Alt+letter is not a card key).
        if (alt) return null;
        return key switch
        {
            Key.A => NotchKey.Always,
            Key.E => NotchKey.Edit,
            Key.Y => NotchKey.Copy,
            Key.D => NotchKey.Diff,
            Key.OemQuestion or Key.Divide => NotchKey.Filter,
            Key.P => NotchKey.MarkdownMode,
            Key.W => NotchKey.Worktree,
            Key.R => NotchKey.Repository,
            Key.C => NotchKey.Commit,
            Key.U => NotchKey.Undo,
            _ => null,
        };
    }
}
