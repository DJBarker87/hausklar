import * as DialogPrimitive from "@radix-ui/react-dialog";
import * as TooltipPrimitive from "@radix-ui/react-tooltip";
import clsx from "clsx";
import { AlertCircle, Inbox, X, type LucideIcon } from "lucide-react";
import { useRef } from "react";
import type { ButtonHTMLAttributes, ReactNode, RefObject } from "react";

export function cn(...values: Array<string | false | null | undefined>): string {
  return clsx(values);
}

type IconButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  label: string;
  icon: LucideIcon;
  tone?: "default" | "primary" | "danger";
};

export function IconButton({ label, icon: Icon, tone = "default", className, ...props }: IconButtonProps) {
  return (
    <TooltipPrimitive.Provider delayDuration={350}>
      <TooltipPrimitive.Root>
        <TooltipPrimitive.Trigger asChild>
          <button
            type="button"
            aria-label={label}
            className={cn("icon-button", `icon-button--${tone}`, className)}
            {...props}
          >
            <Icon aria-hidden="true" size={19} strokeWidth={2} />
          </button>
        </TooltipPrimitive.Trigger>
        <TooltipPrimitive.Portal>
          <TooltipPrimitive.Content className="tooltip" sideOffset={6}>
            {label}
            <TooltipPrimitive.Arrow className="tooltip-arrow" />
          </TooltipPrimitive.Content>
        </TooltipPrimitive.Portal>
      </TooltipPrimitive.Root>
    </TooltipPrimitive.Provider>
  );
}

type ModalProps = {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description?: string;
  children: ReactNode;
  size?: "default" | "wide" | "activity";
  returnFocusRef?: RefObject<HTMLElement | null>;
};

export function Modal({ open, onOpenChange, title, description, children, size = "default", returnFocusRef }: ModalProps) {
  const openedFromRef = useRef<HTMLElement | null>(null);

  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="dialog-overlay" />
        <DialogPrimitive.Content
          className={cn(
            "dialog-content",
            size === "wide" && "dialog-content--wide",
            size === "activity" && "dialog-content--activity",
          )}
          onOpenAutoFocus={() => {
            const activeElement = document.activeElement;
            openedFromRef.current = activeElement instanceof HTMLElement && activeElement !== document.body
              ? activeElement
              : null;
          }}
          onCloseAutoFocus={(event) => {
            const focusTarget = returnFocusRef?.current ?? openedFromRef.current;
            openedFromRef.current = null;
            if (!focusTarget?.isConnected) return;
            event.preventDefault();
            focusTarget.focus();
          }}
        >
          <div className="dialog-heading">
            <div>
              <DialogPrimitive.Title className="dialog-title">{title}</DialogPrimitive.Title>
              {description ? (
                <DialogPrimitive.Description className="dialog-description">
                  {description}
                </DialogPrimitive.Description>
              ) : null}
            </div>
            <DialogPrimitive.Close asChild>
              <button type="button" className="icon-button" aria-label="Close">
                <X aria-hidden="true" size={19} />
              </button>
            </DialogPrimitive.Close>
          </div>
          {children}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

export function ConfirmDialog({
  open,
  onOpenChange,
  title,
  description,
  confirmLabel,
  onConfirm,
  busy = false,
  destructive = false,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  description: string;
  confirmLabel: string;
  onConfirm: () => void;
  busy?: boolean;
  destructive?: boolean;
}) {
  return (
    <DialogPrimitive.Root open={open} onOpenChange={onOpenChange}>
      <DialogPrimitive.Portal>
        <DialogPrimitive.Overlay className="dialog-overlay" />
        <DialogPrimitive.Content className="dialog-content confirm-dialog">
          <DialogPrimitive.Title className="dialog-title">{title}</DialogPrimitive.Title>
          <DialogPrimitive.Description className="dialog-description">{description}</DialogPrimitive.Description>
          <div className="dialog-actions">
            <DialogPrimitive.Close asChild>
              <button type="button" className="button button--secondary" disabled={busy}>Cancel</button>
            </DialogPrimitive.Close>
            <button
              type="button"
              className={cn("button", destructive ? "button--danger" : "button--primary")}
              disabled={busy}
              aria-busy={busy}
              onClick={onConfirm}
            >
              {busy ? "Working…" : confirmLabel}
            </button>
          </div>
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

export function SkeletonList({ rows = 4 }: { rows?: number }) {
  return (
    <div className="skeleton-list" role="status" aria-live="polite" aria-busy="true">
      <span className="sr-only">Loading</span>
      {Array.from({ length: rows }).map((_, index) => (
        <div className="skeleton-row" key={index} />
      ))}
    </div>
  );
}

export function ErrorState({ message, retry }: { message: string; retry?: () => void }) {
  return (
    <div className="state-panel state-panel--error" role="alert">
      <AlertCircle aria-hidden="true" size={22} />
      <div>
        <strong>Couldn't load this view</strong>
        <p>{message}</p>
      </div>
      {retry ? (
        <button type="button" className="button button--secondary" onClick={retry}>
          Try again
        </button>
      ) : null}
    </div>
  );
}

export function EmptyState({
  title,
  detail,
  action,
  actionLabel,
}: {
  title: string;
  detail: string;
  action?: () => void;
  actionLabel?: string;
}) {
  return (
    <div className="empty-state">
      <Inbox aria-hidden="true" size={30} />
      <strong>{title}</strong>
      <p>{detail}</p>
      {action && actionLabel ? (
        <button type="button" className="button button--secondary" onClick={action}>
          {actionLabel}
        </button>
      ) : null}
    </div>
  );
}

export function Segmented<T extends string>({
  value,
  onChange,
  options,
  label,
}: {
  value: T;
  onChange: (value: T) => void;
  options: Array<{ value: T; label: string }>;
  label: string;
}) {
  return (
    <div className="segmented" role="group" aria-label={label}>
      {options.map((option) => (
        <button
          key={option.value}
          type="button"
          className={cn("segmented-item", value === option.value && "is-active")}
          aria-pressed={value === option.value}
          onClick={() => onChange(option.value)}
        >
          {option.label}
        </button>
      ))}
    </div>
  );
}
