using System;
using System.Collections.Generic;
using System.Windows.Forms;

namespace Clipman
{
    public static class TextBoundaryNavigator
    {
        private static readonly Dictionary<TextBoxBase, SelectionState> SelectionStates = new Dictionary<TextBoxBase, SelectionState>();

        public static void Attach(TextBoxBase textBox)
        {
            if (textBox == null) return;
            textBox.KeyDown += TextBoxKeyDown;
            textBox.MouseDown += (sender, e) => ClearState((TextBoxBase)sender);
            textBox.Leave += (sender, e) => ClearState((TextBoxBase)sender);
        }

        private static void TextBoxKeyDown(object sender, KeyEventArgs e)
        {
            if (!e.Control || e.Alt)
            {
                return;
            }

            var textBox = sender as TextBoxBase;
            if (textBox == null)
            {
                return;
            }

            if (e.KeyCode == Keys.Left)
            {
                Move(textBox, -1, e.Shift);
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
            else if (e.KeyCode == Keys.Right)
            {
                Move(textBox, 1, e.Shift);
                e.Handled = true;
                e.SuppressKeyPress = true;
            }
        }

        private static void Move(TextBoxBase textBox, int direction, bool extendSelection)
        {
            var text = textBox.Text ?? string.Empty;
            var state = GetState(textBox);
            var anchor = extendSelection ? SelectionAnchor(textBox, state, direction) : -1;
            var current = CaretPosition(textBox, state, direction, extendSelection);
            var next = direction < 0 ? PreviousBoundary(text, current) : NextBoundary(text, current);

            if (!extendSelection)
            {
                SetSelection(textBox, next, next);
                ClearState(textBox);
                return;
            }

            SelectBetween(textBox, anchor, next);
            SelectionStates[textBox] = new SelectionState(anchor, next);
        }

        private static SelectionState GetState(TextBoxBase textBox)
        {
            SelectionState state;
            if (SelectionStates.TryGetValue(textBox, out state) && StateMatchesSelection(textBox, state))
            {
                return state;
            }

            return new SelectionState(textBox.SelectionStart, textBox.SelectionStart);
        }

        private static bool StateMatchesSelection(TextBoxBase textBox, SelectionState state)
        {
            var start = textBox.SelectionStart;
            var end = start + textBox.SelectionLength;
            return Math.Min(state.Anchor, state.Caret) == start && Math.Max(state.Anchor, state.Caret) == end;
        }

        private static void ClearState(TextBoxBase textBox)
        {
            if (textBox != null)
            {
                SelectionStates.Remove(textBox);
            }
        }

        private static int SelectionAnchor(TextBoxBase textBox, SelectionState state, int direction)
        {
            var start = textBox.SelectionStart;
            var length = textBox.SelectionLength;
            if (length <= 0)
            {
                return start;
            }

            return state.Anchor;
        }

        private static int CaretPosition(TextBoxBase textBox, SelectionState state, int direction, bool extendSelection)
        {
            var start = textBox.SelectionStart;
            var length = textBox.SelectionLength;
            if (length <= 0)
            {
                return start;
            }

            if (extendSelection)
            {
                return state.Caret;
            }

            return direction < 0 ? start : start + length;
        }

        private static void SelectBetween(TextBoxBase textBox, int anchor, int caret)
        {
            if (caret < anchor)
            {
                SetSelection(textBox, caret, anchor);
            }
            else
            {
                SetSelection(textBox, anchor, caret);
            }
        }

        private static void SetSelection(TextBoxBase textBox, int start, int end)
        {
            start = Math.Max(0, Math.Min(start, textBox.TextLength));
            end = Math.Max(0, Math.Min(end, textBox.TextLength));
            textBox.SelectionStart = Math.Min(start, end);
            textBox.SelectionLength = Math.Abs(end - start);
            textBox.ScrollToCaret();
        }

        public static int NextBoundary(string text, int position)
        {
            var length = text.Length;
            if (position >= length)
            {
                return length;
            }

            var category = CharacterCategory(text[position]);
            var index = position + 1;
            while (index < length && CharacterCategory(text[index]) == category)
            {
                index++;
            }

            return index;
        }

        public static int PreviousBoundary(string text, int position)
        {
            if (position <= 0)
            {
                return 0;
            }

            var index = position - 1;
            var category = CharacterCategory(text[index]);
            while (index > 0 && CharacterCategory(text[index - 1]) == category)
            {
                index--;
            }

            return index;
        }

        private static TextCharacterCategory CharacterCategory(char value)
        {
            if (char.IsWhiteSpace(value))
            {
                return TextCharacterCategory.Whitespace;
            }

            if (char.IsLetterOrDigit(value))
            {
                return TextCharacterCategory.Word;
            }

            return TextCharacterCategory.Boundary;
        }

        private enum TextCharacterCategory
        {
            Word,
            Boundary,
            Whitespace
        }

        private struct SelectionState
        {
            public readonly int Anchor;
            public readonly int Caret;

            public SelectionState(int anchor, int caret)
            {
                Anchor = anchor;
                Caret = caret;
            }
        }
    }
}
