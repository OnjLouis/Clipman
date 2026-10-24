namespace Clipman
{
    internal sealed class ClipboardNotificationState
    {
        private uint pendingSequence;
        private long? pendingObservedMilliseconds;
        private uint lastProcessedSequence;
        private uint ignoredSequence;

        public void Observe(uint sequence, long? observedMilliseconds = null)
        {
            if (pendingSequence != sequence || !pendingObservedMilliseconds.HasValue)
                pendingObservedMilliseconds = observedMilliseconds;
            pendingSequence = sequence;
        }

        public uint TakePending()
        {
            long? ignored;
            return TakePending(out ignored);
        }

        public uint TakePending(out long? observedMilliseconds)
        {
            var sequence = pendingSequence;
            observedMilliseconds = pendingObservedMilliseconds;
            pendingSequence = 0;
            pendingObservedMilliseconds = null;
            return sequence;
        }

        internal static long MessageObservedMilliseconds(int messageTicks, int currentTicks, long nowMilliseconds)
        {
            // Native message times wrap at 32 bits; retain queue age, not UI-processing delay.
            return nowMilliseconds - unchecked((uint)(currentTicks - messageTicks));
        }

        public void Ignore(uint sequence)
        {
            ignoredSequence = sequence;
        }

        public bool ShouldProcess(uint sequence, bool recovery)
        {
            if (sequence == 0) return true;

            var duplicate = sequence == lastProcessedSequence;
            lastProcessedSequence = sequence;
            if (sequence == ignoredSequence)
            {
                ignoredSequence = 0;
                return false;
            }
            if (ignoredSequence != 0)
            {
                ignoredSequence = 0;
            }
            return recovery || !duplicate;
        }
    }
}
