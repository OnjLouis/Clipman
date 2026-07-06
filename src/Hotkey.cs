using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows.Forms;

namespace Clipman
{
    internal sealed class HotkeyDefinition
    {
        public NativeMethods.Modifiers Modifiers { get; private set; }
        public Keys Key { get; private set; }

        public static bool TryParse(string text, out HotkeyDefinition definition)
        {
            definition = null;
            if (string.IsNullOrWhiteSpace(text))
            {
                return false;
            }

            var parts = text.Split(new[] { '+' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(p => p.Trim())
                .Where(p => p.Length > 0)
                .ToList();
            if (parts.Count == 0)
            {
                return false;
            }

            var mods = NativeMethods.Modifiers.None;
            Keys key = Keys.None;
            foreach (var part in parts)
            {
                var lower = part.ToLowerInvariant();
                if (lower == "ctrl" || lower == "control")
                {
                    mods |= NativeMethods.Modifiers.Control;
                }
                else if (lower == "alt")
                {
                    mods |= NativeMethods.Modifiers.Alt;
                }
                else if (lower == "shift")
                {
                    mods |= NativeMethods.Modifiers.Shift;
                }
                else if (lower == "win" || lower == "windows")
                {
                    mods |= NativeMethods.Modifiers.Windows;
                }
                else
                {
                    key = ParseKey(part);
                }
            }

            if (key == Keys.None)
            {
                return false;
            }

            definition = new HotkeyDefinition { Modifiers = mods, Key = key };
            return definition.IsValid;
        }

        public static string FromKeys(Keys keys)
        {
            return FromKeys(keys, IsWindowsKeyPressed());
        }

        public static string FromKeys(Keys keys, bool windowsModifierPressed)
        {
            var parts = new List<string>();
            if ((keys & Keys.Control) == Keys.Control) parts.Add("Ctrl");
            if ((keys & Keys.Alt) == Keys.Alt) parts.Add("Alt");
            if ((keys & Keys.Shift) == Keys.Shift) parts.Add("Shift");
            if (windowsModifierPressed) parts.Add("Win");

            var key = keys & Keys.KeyCode;
            if (key != Keys.None)
            {
                parts.Add(KeyToText(key));
            }

            return string.Join("+", parts);
        }

        public static bool IsWindowsKeyPressed()
        {
            return IsKeyPressed(NativeMethods.VK_LWIN) || IsKeyPressed(NativeMethods.VK_RWIN);
        }

        public bool IsValid
        {
            get { return IsAllowedBaseKey(Key) && IsAllowedModifierCombination(Key, Modifiers) && !IsReservedCombination(Key, Modifiers); }
        }

        public static bool IsSingleModifierHotkey(string text)
        {
            HotkeyDefinition definition;
            return TryParse(text, out definition) && ModifierCount(definition.Modifiers) == 1;
        }

        private static bool IsAllowedModifierCombination(Keys key, NativeMethods.Modifiers modifiers)
        {
            var count = ModifierCount(modifiers);
            if (count >= 2) return true;
            if (count != 1) return false;

            if (key >= Keys.F1 && key <= Keys.F24)
            {
                return true;
            }

            if ((modifiers & NativeMethods.Modifiers.Shift) != 0)
            {
                return false;
            }

            return IsAllowedSingleModifierKey(key);
        }

        private static int ModifierCount(NativeMethods.Modifiers modifiers)
        {
            var count = 0;
            if ((modifiers & NativeMethods.Modifiers.Control) != 0) count++;
            if ((modifiers & NativeMethods.Modifiers.Alt) != 0) count++;
            if ((modifiers & NativeMethods.Modifiers.Shift) != 0) count++;
            if ((modifiers & NativeMethods.Modifiers.Windows) != 0) count++;
            return count;
        }

        public static bool IsAllowedBaseKey(Keys key)
        {
            return (key >= Keys.A && key <= Keys.Z) ||
                (key >= Keys.D0 && key <= Keys.D9) ||
                (key >= Keys.NumPad0 && key <= Keys.NumPad9) ||
                (key >= Keys.F1 && key <= Keys.F24) ||
                IsAllowedOemKey(key);
        }

        public static bool IsModifierOnly(Keys keyData)
        {
            var key = keyData & Keys.KeyCode;
            return key == Keys.ControlKey ||
                key == Keys.ShiftKey ||
                key == Keys.Menu ||
                key == Keys.LControlKey ||
                key == Keys.RControlKey ||
                key == Keys.LShiftKey ||
                key == Keys.RShiftKey ||
                key == Keys.LMenu ||
                key == Keys.RMenu ||
                key == Keys.LWin ||
                key == Keys.RWin;
        }

        public static bool IsValidKeyData(Keys keyData)
        {
            HotkeyDefinition definition;
            return TryParse(FromKeys(keyData), out definition);
        }

        private static bool IsReservedCombination(Keys key, NativeMethods.Modifiers modifiers)
        {
            if ((modifiers & NativeMethods.Modifiers.Alt) != 0 && key == Keys.F4)
            {
                return true;
            }

            if ((modifiers & NativeMethods.Modifiers.Control) != 0 && key == Keys.Escape)
            {
                return true;
            }

            if ((modifiers & NativeMethods.Modifiers.Windows) == 0)
            {
                return false;
            }

            if ((key >= Keys.D0 && key <= Keys.D9) || (key >= Keys.NumPad0 && key <= Keys.NumPad9))
            {
                return true;
            }

            return key == Keys.A ||
                key == Keys.D ||
                key == Keys.E ||
                key == Keys.I ||
                key == Keys.L ||
                key == Keys.M ||
                key == Keys.R ||
                key == Keys.S ||
                key == Keys.V ||
                key == Keys.X;
        }

        private static bool IsAllowedOemKey(Keys key)
        {
            switch (key)
            {
                case Keys.Oem5:
                case Keys.Oem3:
                case Keys.Oem1:
                case Keys.Oem7:
                case Keys.Oemcomma:
                case Keys.OemPeriod:
                case Keys.OemQuestion:
                case Keys.OemMinus:
                case Keys.Oemplus:
                case Keys.OemOpenBrackets:
                case Keys.Oem6:
                    return true;
                default:
                    return false;
            }
        }

        private static bool IsAllowedSingleModifierKey(Keys key)
        {
            switch (key)
            {
                case Keys.Oem5:
                case Keys.Oem3:
                    return true;
                default:
                    return false;
            }
        }

        private static bool IsKeyPressed(int virtualKey)
        {
            return (NativeMethods.GetAsyncKeyState(virtualKey) & unchecked((short)0x8000)) != 0;
        }

        private static Keys ParseKey(string part)
        {
            if (part == "\\") return Keys.Oem5;
            if (part == "`") return Keys.Oem3;
            if (part == ";") return Keys.Oem1;
            if (part == "'") return Keys.Oem7;
            if (part == ",") return Keys.Oemcomma;
            if (part == ".") return Keys.OemPeriod;
            if (part == "/") return Keys.OemQuestion;
            if (part == "-") return Keys.OemMinus;
            if (part == "=") return Keys.Oemplus;
            if (part == "[") return Keys.OemOpenBrackets;
            if (part == "]") return Keys.Oem6;

            Keys parsed;
            if (Enum.TryParse(part, true, out parsed))
            {
                return parsed;
            }

            if (part.Length == 1)
            {
                var ch = char.ToUpperInvariant(part[0]);
                if (ch >= 'A' && ch <= 'Z')
                {
                    return (Keys)Enum.Parse(typeof(Keys), ch.ToString(CultureInfo.InvariantCulture));
                }
                if (ch >= '0' && ch <= '9')
                {
                    return (Keys)Enum.Parse(typeof(Keys), "D" + ch.ToString(CultureInfo.InvariantCulture));
                }
            }

            return Keys.None;
        }

        private static string KeyToText(Keys key)
        {
            switch (key)
            {
                case Keys.Oem5: return "\\";
                case Keys.Oem3: return "`";
                case Keys.Oem1: return ";";
                case Keys.Oem7: return "'";
                case Keys.Oemcomma: return ",";
                case Keys.OemPeriod: return ".";
                case Keys.OemQuestion: return "/";
                case Keys.OemMinus: return "-";
                case Keys.Oemplus: return "=";
                case Keys.OemOpenBrackets: return "[";
                case Keys.Oem6: return "]";
                default:
                    if (key >= Keys.D0 && key <= Keys.D9)
                    {
                        return ((char)('0' + (key - Keys.D0))).ToString(CultureInfo.InvariantCulture);
                    }
                    return key.ToString();
            }
        }
    }
}
