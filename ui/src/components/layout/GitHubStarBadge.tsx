// GitHub star badge removed in the white-label build. Renders nothing so
// callers (overview page, workflow editor header) don't need to be touched.
"use client";

interface GitHubStarBadgeProps {
  source?: string;
  label?: string;
  showCount?: boolean;
  className?: string;
}

export function GitHubStarBadge(_: GitHubStarBadgeProps) {
  return null;
}

export default GitHubStarBadge;
