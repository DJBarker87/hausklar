import {
  ArrowDown,
  ArrowUp,
  BookOpen,
  Check,
  ChevronLeft,
  ChevronRight,
  FileDown,
  Images,
  Loader2,
  MapPin,
  Palette,
  RefreshCw,
  Ruler,
  Sparkles,
  Star,
  Thermometer,
  UtensilsCrossed,
} from "lucide-react";
import { format, parseISO } from "date-fns";
import { useCallback, useEffect, useMemo, useState } from "react";

import { ApiError, api } from "../api";
import type { Child } from "../types";
import { EmptyState, ErrorState, Modal, SkeletonList, cn } from "../components/ui";

import "./yearbook-builder.css";

// Mirrors the /api/yearbook contract exactly. Any section may be empty/zero and the
// growth block, item titles, notes and locations are all nullable.
type YearbookArtwork = { id: string; title: string | null; approx_date: string; image_url: string };
type YearbookGrowthPoint = { date: string; height_cm: number | null; weight_kg: number | null };
type YearbookGrowth = {
  start: YearbookGrowthPoint;
  end: YearbookGrowthPoint;
  grew_cm: number | null;
  gained_kg: number | null;
  measurements: number;
};
type YearbookIllness = { started_at: string; notes: string | null };
type YearbookAdventure = { title: string; start_time: string; location: string | null };
type YearbookPhoto = { asset_id: string; thumbnail_url: string };
type YearbookArtworkOption = {
  id: string;
  title: string | null;
  approx_date: string;
  include_in_yearbook: boolean;
  yearbook_position: number | null;
  image_url: string;
};
type YearbookPhotoOption = {
  id: string;
  caption: string | null;
  taken_on: string;
  location: string | null;
  include_in_yearbook: boolean;
  yearbook_position: number | null;
  image_url: string;
};
type YearbookOptions = {
  child: { id: string; name: string };
  year: number;
  artwork: YearbookArtworkOption[];
  photos: YearbookPhotoOption[];
};
type BuilderStep = "choose" | "arrange" | "preview";
type Yearbook = {
  child: { id: string; name: string; age: number };
  year: number;
  narrative: string | null;
  sections: {
    artwork: { count: number; items: YearbookArtwork[] };
    growth: YearbookGrowth | null;
    star_charts: { completed: number; earned_pence: number; titles: string[] };
    learning: { reading_sessions: number; minutes_read: number; books: string[]; book_count: number; spelling_tests: number };
    illnesses: { count: number; items: YearbookIllness[] };
    adventures: { count: number; items: YearbookAdventure[] };
    favourite_meals: string[];
    photos: { count: number; highlights: YearbookPhoto[] };
  };
};

const CURRENT_YEAR = new Date().getFullYear();

function approxDateLabel(value: string): string {
  const parts = value.split("-");
  if (parts.length === 1) return value;
  try {
    if (parts.length === 2) return format(parseISO(`${value}-01`), "MMMM");
    return format(parseISO(value), "d MMMM");
  } catch {
    return value;
  }
}

function photoDateLabel(value: string): string {
  try {
    return format(parseISO(value), "d MMMM");
  } catch {
    return value;
  }
}

function pounds(pence: number): string {
  return `£${(pence / 100).toFixed(2)}`;
}

function ageLabel(age: number): string {
  return age === 1 ? "aged 1" : `aged ${age}`;
}

/** A quiet year has no highlights worth a section of their own. */
function isQuietYear(book: Yearbook): boolean {
  const s = book.sections;
  return (
    !book.narrative &&
    s.artwork.count === 0 &&
    !s.growth &&
    s.star_charts.completed === 0 &&
    s.learning.reading_sessions === 0 &&
    s.learning.book_count === 0 &&
    s.learning.spelling_tests === 0 &&
    s.adventures.count === 0 &&
    s.favourite_meals.length === 0 &&
    s.illnesses.count === 0 &&
    s.photos.count === 0
  );
}

export function YearbookView({ children, initialChildId = null, onChildChange }: { children: Child[]; initialChildId?: string | null; onChildChange?: (childId: string) => void }) {
  const [selectedChild, setSelectedChild] = useState<string>(initialChildId ?? "");
  const [years, setYears] = useState<number[]>([CURRENT_YEAR]);
  const [year, setYear] = useState<number>(CURRENT_YEAR);
  const [book, setBook] = useState<Yearbook | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [refreshNote, setRefreshNote] = useState<string | null>(null);
  const [builderOpen, setBuilderOpen] = useState(false);
  const [builderStep, setBuilderStep] = useState<BuilderStep>("choose");
  const [options, setOptions] = useState<YearbookOptions | null>(null);
  const [artworkOrder, setArtworkOrder] = useState<string[]>([]);
  const [photoOrder, setPhotoOrder] = useState<string[]>([]);
  const [builderLoading, setBuilderLoading] = useState(false);
  const [builderSaving, setBuilderSaving] = useState(false);
  const [builderError, setBuilderError] = useState<string | null>(null);

  // Seed the child from the household roster once it arrives.
  useEffect(() => {
    if (initialChildId && children.some((child) => child.id === initialChildId)) {
      setSelectedChild(initialChildId);
      return;
    }
    setSelectedChild((current) => children.some((child) => child.id === current) ? current : children[0]?.id ?? "");
  }, [children, initialChildId]);

  function selectChild(childId: string) {
    setSelectedChild(childId);
    onChildChange?.(childId);
  }

  // The available years follow the chosen child (current year is always present).
  useEffect(() => {
    if (!selectedChild) return;
    let cancelled = false;
    void api<{ years: number[] }>(`/yearbook/${selectedChild}/years`)
      .then((response) => {
        if (cancelled) return;
        const list = response.years.length ? response.years : [CURRENT_YEAR];
        setYears(list);
        setYear((current) => (list.includes(current) ? current : list[0]));
      })
      .catch(() => {
        if (!cancelled) setYears([CURRENT_YEAR]);
      });
    return () => {
      cancelled = true;
    };
  }, [selectedChild]);

  const load = useCallback(async () => {
    if (!selectedChild) return;
    setLoading(true);
    setError(null);
    setRefreshNote(null);
    try {
      setBook(await api<Yearbook>(`/yearbook/${selectedChild}/${year}`));
    } catch (requestError) {
      setBook(null);
      setError(requestError instanceof Error ? requestError.message : "This yearbook could not be opened.");
    } finally {
      setLoading(false);
    }
  }, [selectedChild, year]);

  useEffect(() => {
    void load();
  }, [load]);

  async function refreshNarrative() {
    if (!selectedChild || refreshing) return;
    setRefreshing(true);
    setRefreshNote(null);
    try {
      setBook(await api<Yearbook>(`/yearbook/${selectedChild}/${year}/refresh`, { method: "POST", timeoutMs: 60_000 }));
    } catch (requestError) {
      if (requestError instanceof ApiError && requestError.status === 429) {
        setRefreshNote("The story was refreshed a few times just now — please try again a little later.");
      } else if (requestError instanceof ApiError && requestError.status === 428) {
        setRefreshNote("Allow OpenAI in Account → AI & Family Data before writing this story.");
      } else {
        setRefreshNote(requestError instanceof Error ? requestError.message : "The story could not be rewritten just now.");
      }
    } finally {
      setRefreshing(false);
    }
  }

  async function openBuilder() {
    if (!selectedChild) return;
    setBuilderOpen(true);
    setBuilderStep("choose");
    setBuilderLoading(true);
    setBuilderError(null);
    try {
      const fetched = await api<YearbookOptions>(`/yearbook/${selectedChild}/${year}/options`);
      setOptions(fetched);
      setArtworkOrder(fetched.artwork.filter((item) => item.include_in_yearbook).map((item) => item.id));
      setPhotoOrder(fetched.photos.filter((item) => item.include_in_yearbook).map((item) => item.id));
    } catch (requestError) {
      setOptions(null);
      setBuilderError(requestError instanceof Error ? requestError.message : "The keepsake choices could not be opened.");
    } finally {
      setBuilderLoading(false);
    }
  }

  function toggleChoice(kind: "artwork" | "photos", id: string) {
    const update = kind === "artwork" ? setArtworkOrder : setPhotoOrder;
    update((current) => current.includes(id) ? current.filter((item) => item !== id) : [...current, id]);
  }

  function moveChoice(kind: "artwork" | "photos", id: string, direction: -1 | 1) {
    const update = kind === "artwork" ? setArtworkOrder : setPhotoOrder;
    update((current) => {
      const index = current.indexOf(id);
      const target = index + direction;
      if (index < 0 || target < 0 || target >= current.length) return current;
      const next = [...current];
      [next[index], next[target]] = [next[target]!, next[index]!];
      return next;
    });
  }

  async function saveArrangement() {
    if (!selectedChild || builderSaving) return;
    setBuilderSaving(true);
    setBuilderError(null);
    try {
      const saved = await api<Yearbook>(`/yearbook/${selectedChild}/${year}/arrangement`, {
        method: "PUT",
        body: JSON.stringify({ artwork_ids: artworkOrder, photo_ids: photoOrder }),
      });
      setBook(saved);
      setBuilderStep("preview");
    } catch (requestError) {
      setBuilderError(requestError instanceof Error ? requestError.message : "The page order could not be saved.");
    } finally {
      setBuilderSaving(false);
    }
  }

  function exportPDF() {
    setBuilderOpen(false);
    window.setTimeout(() => window.print(), 0);
  }

  const sections = book?.sections;
  const growth = sections?.growth ?? null;
  const grewCm = growth?.grew_cm ?? null;
  const gainedKg = growth?.gained_kg ?? null;
  const meals = sections?.favourite_meals ?? [];
  const adventures = sections?.adventures.items ?? [];
  const artworkItems = sections?.artwork.items ?? [];
  const photoHighlights = sections?.photos.highlights ?? [];
  const books = sections?.learning.books ?? [];
  const learning = sections?.learning;
  const stars = sections?.star_charts;
  const illnesses = sections?.illnesses;

  const readingLine = useMemo(() => {
    if (!learning) return null;
    const bits: string[] = [];
    if (learning.reading_sessions) bits.push(`${learning.reading_sessions} reading ${learning.reading_sessions === 1 ? "session" : "sessions"}`);
    if (learning.minutes_read) bits.push(`${learning.minutes_read} minutes of stories`);
    if (learning.spelling_tests) bits.push(`${learning.spelling_tests} spelling ${learning.spelling_tests === 1 ? "test" : "tests"}`);
    return bits.length ? bits.join(" · ") : null;
  }, [learning]);

  const showLearning = Boolean(learning && (learning.reading_sessions || learning.book_count || learning.spelling_tests));
  const selectedArtwork = artworkOrder.flatMap((id) => {
    const item = options?.artwork.find((candidate) => candidate.id === id);
    return item ? [item] : [];
  });
  const selectedPhotos = photoOrder.flatMap((id) => {
    const item = options?.photos.find((candidate) => candidate.id === id);
    return item ? [item] : [];
  });

  return (
    <div className="family-record-section yearbook">
      <div className="yearbook-controls yearbook-no-print">
        <div className="child-filter" role="group" aria-label="Choose child">
          {children.map((child) => (
            <button type="button" className={selectedChild === child.id ? "is-active" : ""} onClick={() => selectChild(child.id)} key={child.id}>
              {child.name}
            </button>
          ))}
        </div>
        <div className="yearbook-controls-right">
          <label className="yearbook-year-select">
            <span className="sr-only">Choose year</span>
            <select value={year} onChange={(event) => setYear(Number(event.target.value))} aria-label="Choose year">
              {years.map((value) => (
                <option value={value} key={value}>{value}</option>
              ))}
            </select>
          </label>
          <button type="button" className="button button--secondary button--compact" onClick={() => void openBuilder()} disabled={!book}>
            <Images aria-hidden="true" size={16} /> Choose & arrange
          </button>
          <button type="button" className="button button--secondary button--compact" onClick={() => window.print()} disabled={!book}>
            <FileDown aria-hidden="true" size={16} /> Export PDF
          </button>
        </div>
      </div>

      {error ? <ErrorState message={error} retry={load} /> : null}
      {loading ? <SkeletonList rows={6} /> : null}

      {!loading && !error && book ? (
        <article className="yearbook-page">
          <header className="yearbook-cover">
            <p className="yearbook-cover-eyebrow">The Yearbook</p>
            <h1 className="yearbook-cover-name">{book.child.name}</h1>
            <p className="yearbook-cover-meta">{book.year} · {ageLabel(book.child.age)}</p>
          </header>

          <section className="yearbook-narrative" aria-label="Our year">
            {book.narrative ? (
              <blockquote className="yearbook-quote">{book.narrative}</blockquote>
            ) : (
              <p className="yearbook-quote yearbook-quote--empty">
                A whole year of little moments{isQuietYear(book) ? "" : " — captured below"}. Write the story of {book.child.name}'s year whenever you're ready.
              </p>
            )}
            <div className="yearbook-narrative-actions yearbook-no-print">
              <button type="button" className="yearbook-refresh" onClick={() => void refreshNarrative()} disabled={refreshing}>
                {refreshing ? <RefreshCw aria-hidden="true" size={14} className="is-spinning" /> : <Sparkles aria-hidden="true" size={14} />}
                {book.narrative ? (refreshing ? "Rewriting…" : "Rewrite the story") : (refreshing ? "Writing…" : "Write the story")}
              </button>
              {refreshNote ? <span className="yearbook-refresh-note" role="status">{refreshNote}</span> : null}
            </div>
          </section>

          {isQuietYear(book) ? (
            <EmptyState
              title="A gentle year, so far"
              detail={`Add artwork, adventures, photos and measurements through the year and ${book.child.name}'s ${book.year} keepsake will fill these pages.`}
            />
          ) : null}

          {growth ? (
            <section className="yearbook-section yearbook-growth" aria-labelledby="yearbook-growth-heading">
              <div className="yearbook-section-head"><Ruler aria-hidden="true" size={18} /><h2 id="yearbook-growth-heading">How they grew</h2></div>
              <div className="yearbook-growth-stats">
                {grewCm != null && grewCm > 0 ? (
                  <div className="yearbook-stat"><strong>{grewCm % 1 === 0 ? grewCm : grewCm.toFixed(1)} cm</strong><span>taller</span></div>
                ) : null}
                {gainedKg != null && gainedKg > 0 ? (
                  <div className="yearbook-stat"><strong>{gainedKg % 1 === 0 ? gainedKg : gainedKg.toFixed(1)} kg</strong><span>heavier</span></div>
                ) : null}
                <div className="yearbook-stat yearbook-stat--muted"><strong>{growth.measurements}</strong><span>{growth.measurements === 1 ? "measurement" : "measurements"}</span></div>
              </div>
              {growth.start.height_cm != null && growth.end.height_cm != null ? (
                <p className="yearbook-growth-line">From {growth.start.height_cm} cm to {growth.end.height_cm} cm across the year.</p>
              ) : null}
            </section>
          ) : null}

          {artworkItems.length ? (
            <section className="yearbook-section" aria-labelledby="yearbook-artwork-heading">
              <div className="yearbook-section-head"><Palette aria-hidden="true" size={18} /><h2 id="yearbook-artwork-heading">Masterpieces</h2><span className="yearbook-count">{sections?.artwork.count}</span></div>
              <div className="yearbook-artwork-strip">
                {artworkItems.map((item) => (
                  <figure className="yearbook-artwork" key={item.id}>
                    <img src={`/api${item.image_url}`} alt={item.title ?? "A drawing"} loading="lazy" />
                    <figcaption>{item.title ?? approxDateLabel(item.approx_date)}</figcaption>
                  </figure>
                ))}
              </div>
            </section>
          ) : null}

          {adventures.length ? (
            <section className="yearbook-section" aria-labelledby="yearbook-adventures-heading">
              <div className="yearbook-section-head"><MapPin aria-hidden="true" size={18} /><h2 id="yearbook-adventures-heading">Adventures</h2><span className="yearbook-count">{sections?.adventures.count}</span></div>
              <ul className="yearbook-adventures">
                {adventures.map((item, index) => (
                  <li key={`${item.title}-${index}`}>
                    <span className="yearbook-adventure-date">{format(parseISO(item.start_time), "d MMM")}</span>
                    <span className="yearbook-adventure-title">{item.title}</span>
                    {item.location ? <span className="yearbook-adventure-place">{item.location}</span> : null}
                  </li>
                ))}
              </ul>
            </section>
          ) : null}

          {stars && stars.completed ? (
            <section className="yearbook-section" aria-labelledby="yearbook-stars-heading">
              <div className="yearbook-section-head"><Star aria-hidden="true" size={18} fill="currentColor" /><h2 id="yearbook-stars-heading">Star charts</h2></div>
              <p className="yearbook-stars-line">
                <strong>{stars.completed}</strong> {stars.completed === 1 ? "chart" : "charts"} completed
                {stars.earned_pence ? <> · <strong>{pounds(stars.earned_pence)}</strong> earned</> : null}
              </p>
              {stars.titles.length ? (
                <div className="yearbook-pills">{stars.titles.map((title, index) => <span className="yearbook-pill" key={`${title}-${index}`}>{title}</span>)}</div>
              ) : null}
            </section>
          ) : null}

          {showLearning ? (
            <section className="yearbook-section" aria-labelledby="yearbook-learning-heading">
              <div className="yearbook-section-head"><BookOpen aria-hidden="true" size={18} /><h2 id="yearbook-learning-heading">Books &amp; learning</h2></div>
              {readingLine ? <p className="yearbook-learning-line">{readingLine}</p> : null}
              {books.length ? (
                <div className="yearbook-pills">{books.map((title, index) => <span className="yearbook-pill" key={`${title}-${index}`}>{title}</span>)}</div>
              ) : null}
              {learning && learning.book_count > books.length ? <p className="yearbook-subtle">…and {learning.book_count - books.length} more.</p> : null}
            </section>
          ) : null}

          {meals.length ? (
            <section className="yearbook-section" aria-labelledby="yearbook-meals-heading">
              <div className="yearbook-section-head"><UtensilsCrossed aria-hidden="true" size={18} /><h2 id="yearbook-meals-heading">Favourite dinners</h2></div>
              <div className="yearbook-pills">{meals.map((meal, index) => <span className="yearbook-pill yearbook-pill--warm" key={`${meal}-${index}`}>{meal}</span>)}</div>
            </section>
          ) : null}

          {photoHighlights.length ? (
            <section className="yearbook-section" aria-labelledby="yearbook-photos-heading">
              <div className="yearbook-section-head"><h2 id="yearbook-photos-heading">Snapshots</h2><span className="yearbook-count">{sections?.photos.count}</span></div>
              <div className="yearbook-photo-strip">
                {photoHighlights.map((photo) => (
                  <img src={`/api${photo.thumbnail_url}`} alt="A family photo" loading="lazy" key={photo.asset_id} />
                ))}
              </div>
            </section>
          ) : null}

          {illnesses && illnesses.count ? (
            <section className="yearbook-section yearbook-illness" aria-labelledby="yearbook-illness-heading">
              <div className="yearbook-section-head"><Thermometer aria-hidden="true" size={18} /><h2 id="yearbook-illness-heading">Poorly days</h2></div>
              <p className="yearbook-subtle">{illnesses.count} {illnesses.count === 1 ? "spell" : "spells"} of being under the weather — and always better again.</p>
              {illnesses.items.some((item) => item.notes) ? (
                <ul className="yearbook-illness-list">
                  {illnesses.items.filter((item) => item.notes).map((item, index) => (
                    <li key={`${item.started_at}-${index}`}><span>{format(parseISO(item.started_at), "d MMM")}</span> {item.notes}</li>
                  ))}
                </ul>
              ) : null}
            </section>
          ) : null}

          <footer className="yearbook-footer">
            <span>{book.child.name} · {book.year}</span>
            <span>Made with HausKlar</span>
          </footer>
        </article>
      ) : null}

      <Modal
        open={builderOpen}
        onOpenChange={(open) => { if (!builderSaving) setBuilderOpen(open); }}
        title={builderStep === "choose" ? "Choose the moments" : builderStep === "arrange" ? "Arrange the pages" : "Your yearbook is ready"}
        description={`${children.find((child) => child.id === selectedChild)?.name ?? "This child"} · ${year}`}
        size="wide"
      >
        <div className="yearbook-builder">
          <ol className="yearbook-builder__steps" aria-label="Yearbook steps">
            {(["choose", "arrange", "preview"] as const).map((step, index) => {
              const currentIndex = (["choose", "arrange", "preview"] as const).indexOf(builderStep);
              const done = index < currentIndex;
              return <li className={cn(step === builderStep && "is-current", done && "is-done")} aria-current={step === builderStep ? "step" : undefined} key={step}><span>{done ? <Check aria-hidden="true" size={14} /> : index + 1}</span>{step === "choose" ? "Choose" : step === "arrange" ? "Arrange" : "Preview"}</li>;
            })}
          </ol>

          {builderLoading ? <SkeletonList rows={5} /> : null}
          {builderError ? <div className="partial-notice inline-recovery" role="alert"><span>{builderError}</span>{!options ? <button type="button" className="button button--secondary button--compact" onClick={() => void openBuilder()}>Try again</button> : null}</div> : null}

          {!builderLoading && options && builderStep === "choose" ? (
            <div className="yearbook-builder__choose">
              <div className="yearbook-builder__intro"><div><strong>{artworkOrder.length + photoOrder.length} keepsakes chosen</strong><span>Growth, adventures, books, star charts and family favourites are added automatically.</span></div></div>
              <section>
                <div className="yearbook-builder__section-head"><h3>Photos</h3><span>{photoOrder.length} of {options.photos.length}</span></div>
                {options.photos.length ? <div className="yearbook-builder__choices">{options.photos.map((item) => {
                  const checked = photoOrder.includes(item.id);
                  return <label className={cn("yearbook-builder__choice", checked && "is-selected")} key={item.id}>
                    <input type="checkbox" checked={checked} onChange={() => toggleChoice("photos", item.id)} />
                    <img src={`/api${item.image_url}`} alt="" loading="lazy" />
                    <span><strong>{item.caption || photoDateLabel(item.taken_on)}</strong><small>{item.location ? `${photoDateLabel(item.taken_on)} · ${item.location}` : photoDateLabel(item.taken_on)}</small></span>
                    <i aria-hidden="true">{checked ? <Check size={14} /> : null}</i>
                  </label>;
                })}</div> : <p className="yearbook-builder__empty">No photos were added for this year.</p>}
              </section>
              <section>
                <div className="yearbook-builder__section-head"><h3>Artwork</h3><span>{artworkOrder.length} of {options.artwork.length}</span></div>
                {options.artwork.length ? <div className="yearbook-builder__choices">{options.artwork.map((item) => {
                  const checked = artworkOrder.includes(item.id);
                  return <label className={cn("yearbook-builder__choice", checked && "is-selected")} key={item.id}>
                    <input type="checkbox" checked={checked} onChange={() => toggleChoice("artwork", item.id)} />
                    <img src={`/api${item.image_url}`} alt="" loading="lazy" />
                    <span><strong>{item.title || "Untitled artwork"}</strong><small>{approxDateLabel(item.approx_date)}</small></span>
                    <i aria-hidden="true">{checked ? <Check size={14} /> : null}</i>
                  </label>;
                })}</div> : <p className="yearbook-builder__empty">No artwork was added for this year.</p>}
              </section>
            </div>
          ) : null}

          {!builderLoading && options && builderStep === "arrange" ? (
            <div className="yearbook-builder__arrange">
              <p>Put the strongest memory first. Each set keeps its own simple order in the finished book.</p>
              <section>
                <div className="yearbook-builder__section-head"><h3>Photo order</h3><span>{selectedPhotos.length}</span></div>
                {selectedPhotos.length ? <ol className="yearbook-builder__order">{selectedPhotos.map((item, index) => <li key={item.id}>
                  <span className="yearbook-builder__position">{index + 1}</span><img src={`/api${item.image_url}`} alt="" /><span><strong>{item.caption || photoDateLabel(item.taken_on)}</strong><small>{item.location || photoDateLabel(item.taken_on)}</small></span>
                  <span className="yearbook-builder__move"><button type="button" aria-label={`Move ${item.caption || "photo"} earlier`} disabled={index === 0} onClick={() => moveChoice("photos", item.id, -1)}><ArrowUp aria-hidden="true" size={17} /></button><button type="button" aria-label={`Move ${item.caption || "photo"} later`} disabled={index === selectedPhotos.length - 1} onClick={() => moveChoice("photos", item.id, 1)}><ArrowDown aria-hidden="true" size={17} /></button></span>
                </li>)}</ol> : <p className="yearbook-builder__empty">No photos selected.</p>}
              </section>
              <section>
                <div className="yearbook-builder__section-head"><h3>Artwork order</h3><span>{selectedArtwork.length}</span></div>
                {selectedArtwork.length ? <ol className="yearbook-builder__order">{selectedArtwork.map((item, index) => <li key={item.id}>
                  <span className="yearbook-builder__position">{index + 1}</span><img src={`/api${item.image_url}`} alt="" /><span><strong>{item.title || "Untitled artwork"}</strong><small>{approxDateLabel(item.approx_date)}</small></span>
                  <span className="yearbook-builder__move"><button type="button" aria-label={`Move ${item.title || "artwork"} earlier`} disabled={index === 0} onClick={() => moveChoice("artwork", item.id, -1)}><ArrowUp aria-hidden="true" size={17} /></button><button type="button" aria-label={`Move ${item.title || "artwork"} later`} disabled={index === selectedArtwork.length - 1} onClick={() => moveChoice("artwork", item.id, 1)}><ArrowDown aria-hidden="true" size={17} /></button></span>
                </li>)}</ol> : <p className="yearbook-builder__empty">No artwork selected.</p>}
              </section>
            </div>
          ) : null}

          {!builderLoading && options && builderStep === "preview" ? (
            <div className="yearbook-builder__preview">
              <article>
                <p>The Yearbook</p><h2>{options.child.name}</h2><span>{year}</span>
                {selectedPhotos.length || selectedArtwork.length ? <div>{[...selectedPhotos, ...selectedArtwork].slice(0, 8).map((item) => <img src={`/api${item.image_url}`} alt="" key={item.id} />)}</div> : <p className="yearbook-builder__preview-empty">A quiet year, held gently.</p>}
                <footer>{photoOrder.length} photos · {artworkOrder.length} pieces of artwork</footer>
              </article>
              <div><Check aria-hidden="true" size={22} /><strong>Selection and order saved</strong><span>The full preview behind this window also includes growth, adventures, books, star charts and favourite meals.</span></div>
            </div>
          ) : null}

          {!builderLoading && options ? <div className="yearbook-builder__actions">
            {builderStep !== "choose" ? <button type="button" className="button button--secondary" disabled={builderSaving} onClick={() => setBuilderStep(builderStep === "preview" ? "arrange" : "choose")}><ChevronLeft aria-hidden="true" size={17} /> Back</button> : <span />}
            {builderStep === "choose" ? <button type="button" className="button button--primary" onClick={() => setBuilderStep("arrange")}>Arrange pages <ChevronRight aria-hidden="true" size={17} /></button> : null}
            {builderStep === "arrange" ? <button type="button" className="button button--primary" disabled={builderSaving} onClick={() => void saveArrangement()}>{builderSaving ? <Loader2 className="spin" aria-hidden="true" size={17} /> : null}{builderSaving ? "Saving…" : "Preview yearbook"}<ChevronRight aria-hidden="true" size={17} /></button> : null}
            {builderStep === "preview" ? <div><button type="button" className="button button--secondary" onClick={() => setBuilderOpen(false)}>Done</button><button type="button" className="button button--primary" onClick={exportPDF}><FileDown aria-hidden="true" size={17} /> Export PDF</button></div> : null}
          </div> : null}
        </div>
      </Modal>
    </div>
  );
}
