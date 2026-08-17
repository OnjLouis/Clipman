using System;
using System.Collections.Generic;

namespace Clipman
{
    internal sealed class ClipboardApplicationCompatibilityRule
    {
        internal ClipboardApplicationCompatibilityRule(
            int duplicateNotificationMilliseconds,
            bool acceptChangingSequenceIdentifiers)
        {
            DuplicateNotificationMilliseconds = duplicateNotificationMilliseconds;
            AcceptChangingSequenceIdentifiers = acceptChangingSequenceIdentifiers;
        }

        internal int DuplicateNotificationMilliseconds { get; private set; }
        internal bool AcceptChangingSequenceIdentifiers { get; private set; }
    }

    internal static class ClipboardApplicationCompatibility
    {
        internal const int DefaultDuplicateNotificationMilliseconds = 60;

        private static readonly ClipboardApplicationCompatibilityRule DefaultRule =
            new ClipboardApplicationCompatibilityRule(DefaultDuplicateNotificationMilliseconds, false);

        private static readonly ClipboardApplicationCompatibilityRule MozillaRule =
            new ClipboardApplicationCompatibilityRule(500, true);

        private static readonly Dictionary<string, ClipboardApplicationCompatibilityRule> RulesByProcess =
            new Dictionary<string, ClipboardApplicationCompatibilityRule>(StringComparer.OrdinalIgnoreCase)
        {
            // Mozilla applications can publish a delayed second notification for one copy command.
            { "firefox", MozillaRule },
            { "thunderbird", MozillaRule }
        };

        internal static ClipboardApplicationCompatibilityRule ForProcess(string processName)
        {
            ClipboardApplicationCompatibilityRule rule;
            return RulesByProcess.TryGetValue((processName ?? string.Empty).Trim(), out rule)
                ? rule
                : DefaultRule;
        }
    }
}
