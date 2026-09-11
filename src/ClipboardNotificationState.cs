namespace Clipman
{
    internal sealed class ClipboardNotificationState
    {
        private uint pendingSequence;
        private uint lastProcessedSequence;
        private uint ignoredSequence;

        public void Observe(uint sequence)
        {
            pendingSequence = sequence;
        }

        public uint TakePending()
        {
            var sequence = pendingSequence;
            pendingSequence = 0;
            return sequence;
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
