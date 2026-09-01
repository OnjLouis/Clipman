using System;
using System.Runtime.InteropServices;

namespace Clipman
{
    internal static class KeyboardInput
    {
        public static NativeMethods.Input[] BuildControlVPasteInputs()
        {
            return new[]
            {
                Key(NativeMethods.VK_CONTROL, false),
                Key(NativeMethods.VK_V, false),
                Key(NativeMethods.VK_V, true),
                Key(NativeMethods.VK_CONTROL, true)
            };
        }

        public static bool SendControlVPaste()
        {
            var inputs = BuildControlVPasteInputs();
            return NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(NativeMethods.Input))) == inputs.Length;
        }

        private static NativeMethods.Input Key(int virtualKey, bool keyUp)
        {
            var input = new NativeMethods.Input();
            input.Type = NativeMethods.INPUT_KEYBOARD;
            input.Data.Keyboard.VirtualKey = (ushort)virtualKey;
            input.Data.Keyboard.Flags = keyUp ? (uint)NativeMethods.KEYEVENTF_KEYUP : 0;
            return input;
        }
    }
}
