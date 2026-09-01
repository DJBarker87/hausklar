import { Camera, FileText, ImagePlus, Link2, LoaderCircle, Plus, RefreshCw, X } from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { api } from "../api";
import type {
  CalendarEventAttachment,
  CalendarEventAttachmentRole,
  FamilyDocument,
  LinkedDocument,
} from "../types";

export type PendingDocumentAttachment = {
  documentID: string;
  file: File;
  source: "scan" | "photo" | "file";
};

export type EventAttachmentSelection = {
  documentID: string;
  role: CalendarEventAttachmentRole;
};

export type PendingEventAttachment = {
  pending: PendingDocumentAttachment;
  role: CalendarEventAttachmentRole;
};

export const eventAttachmentRoleOptions: Array<{
  value: CalendarEventAttachmentRole;
  label: string;
}> = [
  { value: "ticket", label: "Ticket" },
  { value: "booking", label: "Booking" },
  { value: "school_letter", label: "School letter" },
  { value: "insurance", label: "Insurance" },
  { value: "other", label: "Other" },
];

function documentTitle(file: File): string {
  return file.name.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ").trim() || "Attachment";
}

const supportedFileTypes = new Set([
  "application/pdf",
  "image/heic",
  "image/heif",
  "image/jpeg",
  "image/png",
  "image/tiff",
  "text/plain",
]);

const extensionTypes: Record<string, string> = {
  heic: "image/heic",
  heif: "image/heif",
  jpeg: "image/jpeg",
  jpg: "image/jpeg",
  pdf: "application/pdf",
  png: "image/png",
  tif: "image/tiff",
  tiff: "image/tiff",
  txt: "text/plain",
};

export const DOCUMENT_IMAGE_ACCEPT = "image/jpeg,image/png,image/tiff,image/heic,image/heif";
export const DOCUMENT_FILE_ACCEPT = `${DOCUMENT_IMAGE_ACCEPT},application/pdf,text/plain`;

export function supportedDocumentFile(file: File): File | null {
  const mediaType = file.type.toLocaleLowerCase();
  if (supportedFileTypes.has(mediaType)) return file;
  if (mediaType) return null;
  const extension = file.name.split(".").pop()?.toLocaleLowerCase() ?? "";
  const inferredType = extensionTypes[extension];
  return inferredType
    ? new File([file], file.name, { type: inferredType, lastModified: file.lastModified })
    : null;
}

export async function uploadPendingDocument(
  pending: PendingDocumentAttachment,
): Promise<FamilyDocument> {
  const form = new FormData();
  form.set("document_id", pending.documentID);
  form.set("file", pending.file);
  form.set("title", documentTitle(pending.file));
  form.set("source", pending.source);
  form.set("category", "other");
  form.set("person_ids", "[]");
  form.set("suggestions", "[]");
  form.set("use_hermes", "false");
  return api<FamilyDocument>("/documents/", {
    method: "POST",
    body: form,
    timeoutMs: 120_000,
  });
}

function PendingEventAttachmentPreview({ attachment }: { attachment: PendingEventAttachment }) {
  const previewURL = useMemo(
    () => attachment.pending.file.type.startsWith("image/")
      ? URL.createObjectURL(attachment.pending.file)
      : null,
    [attachment.pending.file],
  );
  useEffect(() => () => {
    if (previewURL) URL.revokeObjectURL(previewURL);
  }, [previewURL]);
  return previewURL
    ? <img src={previewURL} alt={`Preview of ${attachment.pending.file.name}`} />
    : <FileText aria-hidden="true" size={20} />;
}

export function DocumentAttachmentField({
  active,
  idPrefix,
  currentDocument,
  selectedDocumentID,
  pending,
  disabled = false,
  onSelect,
  onPending,
  onUploadBlockedChange,
}: {
  active: boolean;
  idPrefix: string;
  currentDocument?: LinkedDocument | null;
  selectedDocumentID: string | null;
  pending: PendingDocumentAttachment | null;
  disabled?: boolean;
  onSelect: (documentID: string | null) => void;
  onPending: (pending: PendingDocumentAttachment | null) => void;
  onUploadBlockedChange?: (blocked: boolean) => void;
}) {
  const [documents, setDocuments] = useState<FamilyDocument[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const scanInput = useRef<HTMLInputElement>(null);
  const uploadInput = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await api<FamilyDocument[]>("/documents/?limit=200");
      setDocuments(Array.isArray(result) ? result : []);
      setLoaded(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Documents could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    onUploadBlockedChange?.(false);
    return () => onUploadBlockedChange?.(false);
  }, [onUploadBlockedChange]);

  useEffect(() => {
    if (active && !loaded && !loading && !error) void load();
  }, [active, error, load, loaded, loading]);

  const available = useMemo(() => {
    const byID = new Map<string, Pick<FamilyDocument, "id" | "title" | "original_filename">>();
    if (currentDocument) byID.set(currentDocument.id, currentDocument);
    for (const document of documents) byID.set(document.id, document);
    return [...byID.values()];
  }, [currentDocument, documents]);

  const previewURL = useMemo(
    () => pending?.file.type.startsWith("image/") ? URL.createObjectURL(pending.file) : null,
    [pending],
  );
  useEffect(() => () => {
    if (previewURL) URL.revokeObjectURL(previewURL);
  }, [previewURL]);

  function chooseFile(file: File | null, source: PendingDocumentAttachment["source"]) {
    if (!file) return;
    const accepted = supportedDocumentFile(file);
    if (!accepted || (source === "scan" && !accepted.type.startsWith("image/"))) {
      setFileError("Use a JPEG, PNG, TIFF, HEIC, PDF or plain-text file.");
      return;
    }
    setFileError(null);
    onSelect(null);
    onPending({
      documentID: crypto.randomUUID(),
      file: accepted,
      source: source === "file" && accepted.type.startsWith("image/") ? "photo" : source,
    });
  }

  return (
    <fieldset className="document-attachment-field" disabled={disabled}>
      <legend><Link2 aria-hidden="true" size={17} /> Attachment (optional)</legend>
      <p className="field-help">Keep the original document or photo with this item.</p>
      {loading ? <div className="attachment-loading" role="status"><LoaderCircle className="spin" aria-hidden="true" size={17} /> Loading documents…</div> : null}
      {error ? (
        <div className="attachment-error" role="alert">
          <span>{error}</span>
          <button type="button" className="button button--secondary button--compact" onClick={() => void load()}>
            <RefreshCw aria-hidden="true" size={15} /> Retry
          </button>
        </div>
      ) : null}
      {fileError ? <div className="attachment-error" role="alert"><span>{fileError}</span></div> : null}
      <div className="field">
        <label htmlFor={`${idPrefix}-linked-document`}>Choose an existing document</label>
        <select
          id={`${idPrefix}-linked-document`}
          value={pending ? "" : selectedDocumentID ?? ""}
          onChange={(event) => {
            onPending(null);
            onSelect(event.target.value || null);
          }}
        >
          <option value="">No document attached</option>
          {available.map((document) => (
            <option value={document.id} key={document.id}>{document.title} · {document.original_filename}</option>
          ))}
        </select>
        {!loaded && loading ? <span className="field-help">Loading saved documents…</span> : loaded && !available.length ? <span className="field-help">No saved documents yet. Add one below.</span> : null}
      </div>

      <div className="attachment-picker-actions">
        <button type="button" className="button button--secondary" disabled={disabled} onClick={() => scanInput.current?.click()}>
          <Camera aria-hidden="true" size={17} /> Scan document
        </button>
        <button type="button" className="button button--secondary" disabled={disabled} onClick={() => uploadInput.current?.click()}>
          <ImagePlus aria-hidden="true" size={17} /> Upload photo or file
        </button>
        <input
          ref={scanInput}
          className="sr-only"
          type="file"
          aria-hidden="true"
          tabIndex={-1}
          accept={DOCUMENT_IMAGE_ACCEPT}
          capture="environment"
          disabled={disabled}
          aria-label="Scan document with camera"
          onChange={(event) => {
            chooseFile(event.target.files?.[0] ?? null, "scan");
            event.target.value = "";
          }}
        />
        <input
          ref={uploadInput}
          className="sr-only"
          type="file"
          aria-hidden="true"
          tabIndex={-1}
          accept={DOCUMENT_FILE_ACCEPT}
          disabled={disabled}
          aria-label="Upload photo or document"
          onChange={(event) => {
            chooseFile(event.target.files?.[0] ?? null, "file");
            event.target.value = "";
          }}
        />
      </div>

      {pending ? (
        <div className="pending-attachment">
          {previewURL ? <img src={previewURL} alt={`Preview of ${pending.file.name}`} /> : <FileText aria-hidden="true" size={24} />}
          <span><strong>{pending.file.name}</strong><small>{Math.max(1, Math.round(pending.file.size / 1024))} KB · uploads when you save</small></span>
          <button type="button" className="icon-button" aria-label={`Remove ${pending.file.name}`} onClick={() => onPending(null)}>
            <X aria-hidden="true" size={18} />
          </button>
        </div>
      ) : null}
    </fieldset>
  );
}

export function EventDocumentAttachmentsField({
  active,
  currentAttachments,
  selections,
  pending,
  disabled = false,
  onSelectionsChange,
  onPendingChange,
}: {
  active: boolean;
  currentAttachments: CalendarEventAttachment[];
  selections: EventAttachmentSelection[];
  pending: PendingEventAttachment[];
  disabled?: boolean;
  onSelectionsChange: (attachments: EventAttachmentSelection[]) => void;
  onPendingChange: (attachments: PendingEventAttachment[]) => void;
}) {
  const [documents, setDocuments] = useState<FamilyDocument[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [fileError, setFileError] = useState<string | null>(null);
  const [documentID, setDocumentID] = useState("");
  const [role, setRole] = useState<CalendarEventAttachmentRole>("other");
  const uploadInput = useRef<HTMLInputElement>(null);
  const scanInput = useRef<HTMLInputElement>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const result = await api<FamilyDocument[]>("/documents/?limit=200");
      setDocuments(Array.isArray(result) ? result : []);
      setLoaded(true);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Documents could not be loaded.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (active && !loaded && !loading && !error) void load();
  }, [active, error, load, loaded, loading]);

  const available = useMemo(() => {
    const byID = new Map<string, Pick<FamilyDocument, "id" | "title" | "original_filename">>();
    for (const document of currentAttachments) byID.set(document.id, document);
    for (const document of documents) byID.set(document.id, document);
    return [...byID.values()];
  }, [currentAttachments, documents]);
  const byID = useMemo(
    () => new Map(available.map((document) => [document.id, document])),
    [available],
  );

  function addExisting(nextDocumentID = documentID) {
    if (!nextDocumentID || selections.some((item) => item.documentID === nextDocumentID)) return;
    onSelectionsChange([...selections, { documentID: nextDocumentID, role }]);
    setDocumentID("");
    setRole("other");
  }

  function chooseFiles(files: FileList | null, source: PendingDocumentAttachment["source"]) {
    if (!files?.length) return;
    const additions: PendingEventAttachment[] = [];
    for (const file of Array.from(files)) {
      const accepted = supportedDocumentFile(file);
      if (!accepted || (source === "scan" && !accepted.type.startsWith("image/"))) {
        setFileError("Use a JPEG, PNG, TIFF, HEIC, PDF or plain-text file.");
        continue;
      }
      additions.push({
        pending: {
          documentID: crypto.randomUUID(),
          file: accepted,
          source: source === "file" && accepted.type.startsWith("image/") ? "photo" : source,
        },
        role,
      });
    }
    if (additions.length) {
      setFileError(null);
      onPendingChange([...pending, ...additions].slice(0, Math.max(0, 20 - selections.length)));
      setRole("other");
    }
  }

  return (
    <fieldset className="document-attachment-field event-attachments-field" disabled={disabled}>
      <legend><Link2 aria-hidden="true" size={17} /> Documents</legend>
      <p className="field-help">Keep every useful file with the event, labelled for quick retrieval.</p>
      {loading ? <div className="attachment-loading" role="status"><LoaderCircle className="spin" aria-hidden="true" size={17} /> Loading documents…</div> : null}
      {error ? <div className="attachment-error" role="alert"><span>{error}</span><button type="button" className="button button--secondary button--compact" onClick={() => void load()}><RefreshCw aria-hidden="true" size={15} /> Retry</button></div> : null}
      {fileError ? <div className="attachment-error" role="alert"><span>{fileError}</span></div> : null}

      {selections.length || pending.length ? (
        <div className="event-attachment-list">
          {selections.map((selection, index) => {
            const document = byID.get(selection.documentID);
            return (
              <div className="event-attachment-editor-row" key={selection.documentID}>
                <FileText aria-hidden="true" size={20} />
                <span><strong>{document?.title ?? "Saved document"}</strong><small>{document?.original_filename ?? "Already attached"}</small></span>
                <label className="sr-only" htmlFor={`event-attachment-role-${selection.documentID}`}>Document type</label>
                <select id={`event-attachment-role-${selection.documentID}`} value={selection.role} onChange={(event) => onSelectionsChange(selections.map((item, itemIndex) => itemIndex === index ? { ...item, role: event.target.value as CalendarEventAttachmentRole } : item))}>
                  {eventAttachmentRoleOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}
                </select>
                <button type="button" className="icon-button" aria-label={`Remove ${document?.title ?? "document"}`} onClick={() => onSelectionsChange(selections.filter((_item, itemIndex) => itemIndex !== index))}><X aria-hidden="true" size={18} /></button>
              </div>
            );
          })}
          {pending.map((item, index) => (
            <div className="event-attachment-editor-row" key={item.pending.documentID}>
              <PendingEventAttachmentPreview attachment={item} />
              <span><strong>{item.pending.file.name}</strong><small>Uploads when you save</small></span>
              <label className="sr-only" htmlFor={`pending-event-attachment-role-${item.pending.documentID}`}>Document type</label>
              <select id={`pending-event-attachment-role-${item.pending.documentID}`} value={item.role} onChange={(event) => onPendingChange(pending.map((pendingItem, itemIndex) => itemIndex === index ? { ...pendingItem, role: event.target.value as CalendarEventAttachmentRole } : pendingItem))}>
                {eventAttachmentRoleOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}
              </select>
              <button type="button" className="icon-button" aria-label={`Remove ${item.pending.file.name}`} onClick={() => onPendingChange(pending.filter((_pendingItem, itemIndex) => itemIndex !== index))}><X aria-hidden="true" size={18} /></button>
            </div>
          ))}
        </div>
      ) : <p className="field-help">No documents attached.</p>}

      {selections.length + pending.length < 20 ? (
        <div className="event-attachment-add-row">
          <div className="field">
            <label htmlFor="event-attachment-document">Choose an existing document</label>
            <select id="event-attachment-document" value={documentID} onChange={(event) => { const nextDocumentID = event.target.value; setDocumentID(nextDocumentID); if (nextDocumentID) addExisting(nextDocumentID); }}>
              <option value="">Choose a document</option>
              {available.filter((document) => !selections.some((item) => item.documentID === document.id)).map((document) => <option value={document.id} key={document.id}>{document.title} · {document.original_filename}</option>)}
            </select>
          </div>
          <div className="field">
            <label htmlFor="event-attachment-new-role">Type</label>
            <select id="event-attachment-new-role" value={role} onChange={(event) => setRole(event.target.value as CalendarEventAttachmentRole)}>
              {eventAttachmentRoleOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}
            </select>
          </div>
          <button type="button" className="button button--secondary" disabled={!documentID} onClick={() => addExisting()}><Plus aria-hidden="true" size={17} /> Add</button>
        </div>
      ) : null}
      <div className="attachment-picker-actions">
        <button type="button" className="button button--secondary" onClick={() => scanInput.current?.click()}><Camera aria-hidden="true" size={17} /> Scan</button>
        <button type="button" className="button button--secondary" onClick={() => uploadInput.current?.click()}><ImagePlus aria-hidden="true" size={17} /> Upload files</button>
        <input ref={scanInput} className="sr-only" type="file" accept={DOCUMENT_IMAGE_ACCEPT} capture="environment" aria-label="Scan event document" onChange={(event) => { chooseFiles(event.target.files, "scan"); event.target.value = ""; }} />
        <input ref={uploadInput} className="sr-only" type="file" multiple accept={DOCUMENT_FILE_ACCEPT} aria-label="Upload photo or document" onChange={(event) => { chooseFiles(event.target.files, "file"); event.target.value = ""; }} />
      </div>
    </fieldset>
  );
}
