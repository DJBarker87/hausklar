import {
  BookOpen,
  Cake,
  CalendarDays,
  FileText,
  HeartPulse,
  Image,
  ListChecks,
  Palette,
  RefreshCw,
  Search,
  UserRound,
  type LucideIcon,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useEffect, useRef, useState } from "react";

import { api } from "../api";
import type { GlobalSearchResponse, GlobalSearchResult, GlobalSearchResultKind } from "../types";
import { Modal, SkeletonList } from "./ui";
import "./global-search.css";

const ICONS: Record<GlobalSearchResultKind, LucideIcon> = {
  event: CalendarDays,
  task: ListChecks,
  document: FileText,
  person: UserRound,
  photo: Image,
  artwork: Palette,
  homework: BookOpen,
  health: HeartPulse,
  renewal: RefreshCw,
  birthday: Cake,
};

function dateLabel(value?: string | null): string | null {
  if (!value) return null;
  const normalised = /^\d{4}-\d{2}$/.test(value) ? `${value}-01` : value;
  const parsed = parseISO(normalised);
  if (Number.isNaN(parsed.getTime())) return value;
  return /^\d{4}-\d{2}$/.test(value) ? format(parsed, "MMM yyyy") : format(parsed, "d MMM yyyy");
}

function resultImage(result: GlobalSearchResult): string | null {
  if (!result.image_url) return null;
  if (result.image_url.startsWith("/api/")) return result.image_url;
  return result.image_url.startsWith("/") ? `/api${result.image_url}` : result.image_url;
}

export function GlobalSearch({
  open,
  onOpenChange,
  onOpenResult,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onOpenResult: (path: string) => void;
}) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<GlobalSearchResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [searchedQuery, setSearchedQuery] = useState("");
  const [retryVersion, setRetryVersion] = useState(0);
  const requestID = useRef(0);

  useEffect(() => {
    if (!open) return;
    const term = query.trim();
    if (term.length < 2) {
      requestID.current += 1;
      setResults([]);
      setLoading(false);
      setError(null);
      setSearchedQuery("");
      return;
    }

    const current = ++requestID.current;
    const timeout = window.setTimeout(() => {
      setLoading(true);
      setError(null);
      void api<GlobalSearchResponse>(`/search?q=${encodeURIComponent(term)}&limit=40`)
        .then((response) => {
          if (current !== requestID.current) return;
          setResults(response.results ?? []);
          setSearchedQuery(response.query || term);
        })
        .catch((requestError) => {
          if (current !== requestID.current) return;
          setResults([]);
          setSearchedQuery(term);
          setError(requestError instanceof Error ? requestError.message : "Search is unavailable just now.");
        })
        .finally(() => {
          if (current === requestID.current) setLoading(false);
        });
    }, 250);
    return () => window.clearTimeout(timeout);
  }, [open, query, retryVersion]);

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title="Find anything"
      description="Calendar, tasks, documents and family records — all in one place."
      size="wide"
    >
      <div className="global-search">
        <label className="global-search__field">
          <Search aria-hidden="true" size={20} />
          <span className="sr-only">Search HausKlar</span>
          <input
            type="search"
            value={query}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Try “sports day”, “passport” or a person’s name"
            autoComplete="off"
            autoFocus
          />
        </label>

        {loading ? <SkeletonList rows={4} /> : null}
        {error ? (
          <div className="global-search__message" role="alert">
            <strong>Search didn’t work</strong>
            <p>{error}</p>
            <button type="button" className="button button--secondary" onClick={() => setRetryVersion((value) => value + 1)}>Try again</button>
          </div>
        ) : null}
        {!loading && !error && query.trim().length < 2 ? (
          <div className="global-search__message">
            <Search aria-hidden="true" size={28} />
            <strong>What are you looking for?</strong>
            <p>Type at least two letters. Search never changes anything.</p>
          </div>
        ) : null}
        {!loading && !error && searchedQuery && !results.length ? (
          <div className="global-search__message">
            <strong>No match for “{searchedQuery}”</strong>
            <p>Try a name, a shorter phrase, or a word from the document.</p>
          </div>
        ) : null}
        {!loading && !error && results.length ? (
          <ul className="global-search__results" aria-label="Search results">
            {results.map((result) => {
              const Icon = ICONS[result.kind];
              const image = resultImage(result);
              const date = dateLabel(result.date);
              return (
                <li key={`${result.kind}:${result.id}`}>
                  <button type="button" onClick={() => onOpenResult(result.path)}>
                    {image ? <img src={image} alt="" loading="lazy" /> : <span className="global-search__icon"><Icon aria-hidden="true" size={19} /></span>}
                    <span className="global-search__copy">
                      <strong>{result.title}</strong>
                      <small>{[result.subtitle, date].filter(Boolean).join(" · ")}</small>
                    </span>
                    <span className="global-search__open" aria-hidden="true">Open</span>
                  </button>
                </li>
              );
            })}
          </ul>
        ) : null}
      </div>
    </Modal>
  );
}
