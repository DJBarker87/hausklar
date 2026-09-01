import { LoaderCircle } from "lucide-react";
import { useEffect, useState, type FormEvent } from "react";

import { api } from "../api";
import { Modal } from "./ui";

export function ShoppingItemDialog({
  open,
  onOpenChange,
  onCreated,
  notify,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  onCreated: () => void;
  notify: (message: string) => void;
}) {
  const [name, setName] = useState("");
  const [quantity, setQuantity] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [operation, setOperation] = useState<{ id: string; fingerprint: string; timestamp: string } | null>(null);

  useEffect(() => {
    if (!open) return;
    setName("");
    setQuantity("");
    setError(null);
    setOperation(null);
  }, [open]);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const cleanName = name.trim();
    if (!cleanName || submitting) return;
    setSubmitting(true);
    setError(null);
    try {
      const cleanQuantity = quantity.trim() || null;
      const fingerprint = JSON.stringify({ name: cleanName, quantity: cleanQuantity });
      const nextOperation = operation?.fingerprint === fingerprint
        ? operation
        : { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
      setOperation(nextOperation);
      await api("/meals/shopping", {
        method: "POST",
        body: JSON.stringify({
          id: nextOperation.id,
          name: cleanName,
          quantity: cleanQuantity,
          client_id: nextOperation.id,
          client_timestamp: nextOperation.timestamp,
        }),
      });
      setOperation(null);
      notify(`${cleanName} added to the shopping list.`);
      onCreated();
      onOpenChange(false);
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "The shopping item could not be added.");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title="Add to shopping list"
      description="Add one item without leaving what you are doing."
    >
      <form className="form-stack" onSubmit={submit} aria-busy={submitting}>
        {error ? <div className="form-error" role="alert">{error}</div> : null}
        <div className="field">
          <label htmlFor="global-shopping-name">Item</label>
          <input
            id="global-shopping-name"
            value={name}
            onChange={(event) => setName(event.target.value)}
            autoComplete="off"
            placeholder="Milk"
            required
          />
        </div>
        <div className="field">
          <label htmlFor="global-shopping-quantity">Quantity (optional)</label>
          <input
            id="global-shopping-quantity"
            value={quantity}
            onChange={(event) => setQuantity(event.target.value)}
            autoComplete="off"
            placeholder="2 packs"
          />
        </div>
        <div className="dialog-actions">
          <button type="button" className="button button--secondary" disabled={submitting} onClick={() => onOpenChange(false)}>Cancel</button>
          <button type="submit" className="button button--primary" disabled={submitting || !name.trim()} aria-busy={submitting}>
            {submitting ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
            {submitting ? "Adding…" : "Add item"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
