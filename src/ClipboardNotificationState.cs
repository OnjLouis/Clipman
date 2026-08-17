namespace Clipman
{
    internal sealed class ClipboardNotificationState
    {
        private uint pendingSequence;
        private uint lastProcessedSequence;

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

        public bool ShouldProcess(uint sequence, bool recovery)
        {
            if (sequence == 0) return true;

            var duplicate = sequence == lastProcessedSequence;
            lastProcessedSequence = sequence;
            return recovery || !duplicate;
        }
    }
}
