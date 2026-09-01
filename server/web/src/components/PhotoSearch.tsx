import { ImageOff, Search } from "lucide-react";
import { format, parseISO } from "date-fns";
import { useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { Modal, SkeletonList } from "./ui";

type PhotoResult = { asset_id: string; taken_at: string | null; thumbnail_url: string };
type PhotoSearchResponse = { query: string; results: PhotoResult[] };

function takenLabel(value: string | null): string | null {
  if (!value) return null;
  const parsed = parseISO(value);
  return Number.isNaN(parsed.getTime()) ? null : format(parsed, "d MMM yyyy");
}

export function PhotoSearch({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<PhotoResult[]>([]);
  const [searched, setSearched] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const requestId = useRef(0);

  async function runSearch(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const term = query.trim();
    if (!term || loading) return;
    const current = ++requestId.current;
    setLoading(true);
    setError(null);
    try {
      const response = await api<PhotoSearchResponse>(`/photos/search?q=${encodeURIComponent(term)}&limit=30`);
      if (current !== requestId.current) return;
      setResults(response.results ?? []);
      setSearched(true);
    } catch (requestError) {
      if (current !== requestId.current) return;
      setError(requestError instanceof Error ? requestError.message : "Photos could not be searched just now.");
      setResults([]);
      setSearched(true);
    } finally {
      if (current === requestId.current) setLoading(false);
    }
  }

  return (
    <Modal open={open} onOpenChange={onOpenChange} title="Search photos" description="Find a moment from the family archive." size="wide">
      <div className="photo-search">
        <form className="photo-search-form" onSubmit={runSearch} role="search">
          <label className="search-field">
            <span className="sr-only">Search photos</span>
            <Search aria-hidden="true" size={17} />
            <input
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="Try “beach”, “Child One birthday”, “dog in the snow”"
              autoFocus
            />
          </label>
          <button type="submit" className="button button--primary" disabled={!query.trim() || loading}>
            {loading ? "Searching…" : "Search"}
          </button>
        </form>

        {error ? <div className="form-error" role="alert">{error}</div> : null}
        {loading ? <SkeletonList rows={3} /> : null}

        {!loading && searched && !error && !results.length ? (
          <div className="photo-search-empty">
            <ImageOff aria-hidden="true" size={30} />
            <strong>No photos found</strong>
            <p>Try a different word. If the archive is empty, add photos by installing the Immich app on your phone and turning on backup — your camera roll then flows in automatically.</p>
          </div>
        ) : null}

        {!loading && !searched && !error ? (
          <div className="photo-search-empty">
            <Search aria-hidden="true" size={30} />
            <strong>Search the family archive</strong>
            <p>Describe a person, place or moment to find matching photos.</p>
            <p className="photo-search-hint">Photos come from the Immich app on your phone. Install it, sign in to your home server and turn on backup, and your photos fill in here automatically.</p>
          </div>
        ) : null}

        {!loading && results.length ? (
          <div className="photo-search-grid" aria-label="Search results">
            {results.map((photo) => {
              const label = takenLabel(photo.taken_at);
              return (
                <figure className="photo-search-item" key={photo.asset_id}>
                  <img src={`/api${photo.thumbnail_url}`} alt={label ? `Family photo from ${label}` : "Family photo"} loading="lazy" />
                  {label ? <figcaption>{label}</figcaption> : null}
                </figure>
              );
            })}
          </div>
        ) : null}
      </div>
    </Modal>
  );
}
