import { ExternalLink, FileText } from "lucide-react";
import { useEffect, useState } from "react";

import { api } from "../api";
import type { LinkedDocument } from "../types";
import { Modal } from "./ui";

export function DocumentViewer({
  document,
  onOpenChange,
}: {
  document: LinkedDocument | null;
  onOpenChange: (open: boolean) => void;
}) {
  const documentID = document?.id;
  const downloadURL = document?.download_url;
  const [loaded, setLoaded] = useState(false);
  const [previewURL, setPreviewURL] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    setLoaded(false);
    setPreviewURL(null);
    setError(null);
    if (!documentID || !downloadURL) return;

    const controller = new AbortController();
    let current = true;
    api<unknown>("/auth/web/session", { signal: controller.signal })
      .then(() => {
        if (current) setPreviewURL(downloadURL);
      })
      .catch((requestError: unknown) => {
        if (!current) return;
        setError(requestError instanceof Error
          ? requestError.message
          : "This document could not be opened. Please try again.");
      });
    return () => {
      current = false;
      controller.abort();
    };
  }, [attempt, documentID, downloadURL]);

  function previewFailed() {
    setLoaded(false);
    setError("This file could not be previewed here. Open it separately or try again.");
  }

  return (
    <Modal
      open={Boolean(document)}
      onOpenChange={onOpenChange}
      title={document?.title ?? "Document"}
      description={document?.original_filename}
      size="wide"
    >
      {document ? (
        <div className="document-viewer" aria-busy={!loaded && !error}>
          {!loaded && !error ? <div className="document-viewer-loading" role="status"><FileText aria-hidden="true" size={24} /> Opening document…</div> : null}
          {error ? <div className="attachment-error" role="alert"><span>{error}</span><button type="button" className="button button--secondary button--compact" onClick={() => setAttempt((value) => value + 1)}>Try again</button></div> : null}
          {previewURL && !error && document.media_type.startsWith("image/") ? (
            <img
              src={previewURL}
              alt={document.title}
              onLoad={() => setLoaded(true)}
              onError={previewFailed}
            />
          ) : previewURL && !error ? (
            <iframe
              src={previewURL}
              title={document.title}
              sandbox="allow-same-origin"
              referrerPolicy="no-referrer"
              onLoad={() => setLoaded(true)}
              onError={previewFailed}
            />
          ) : null}
          <div className="dialog-actions">
            <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>Close preview</button>
            {previewURL ? <a className="button button--secondary" href={document.download_url} target="_blank" rel="noreferrer">
              <ExternalLink aria-hidden="true" size={16} /> Open separately
            </a> : null}
          </div>
        </div>
      ) : null}
    </Modal>
  );
}
