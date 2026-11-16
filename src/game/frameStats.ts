// Recent frame times, for the debug overlay and the frameMs() test hook.

export class FrameStats {
  private times: number[] = [];

  constructor(private keep = 120) {}

  add(ms: number): void {
    this.times.push(ms);
    if (this.times.length > this.keep) this.times.shift();
  }

  /** Median of the recorded frame times in milliseconds, or 0 before any frame. */
  median(): number {
    if (this.times.length === 0) return 0;
    const sorted = [...this.times].sort((a, b) => a - b);
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? (sorted[mid] ?? 0) : ((sorted[mid - 1] ?? 0) + (sorted[mid] ?? 0)) / 2;
  }
}
