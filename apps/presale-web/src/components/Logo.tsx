export function Logo({ className = "" }: { className?: string }) {
  return (
    <span className={`font-display text-2xl tracking-tight ${className}`}>
      <span className="text-bit">Bit</span>
      <span className="text-sync">Sync</span>
    </span>
  );
}
