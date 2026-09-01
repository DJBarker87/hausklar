import { LoaderCircle } from "lucide-react";
import { addDays, differenceInCalendarDays, format, parseISO, subDays } from "date-fns";
import { useEffect, useRef, useState, type FormEvent } from "react";

import { api, localISODate, localISODateTime } from "../api";
import type {
  CalendarEvent,
  CalendarEventAttachment,
  CalendarEventAttachmentRole,
  CalendarRecurrenceMutationScope,
  FamilyMember,
} from "../types";
import {
  DocumentAttachmentField,
  EventDocumentAttachmentsField,
  uploadPendingDocument,
  type EventAttachmentSelection,
  type PendingDocumentAttachment,
  type PendingEventAttachment,
} from "./DocumentAttachmentField";
import { Modal, Segmented } from "./ui";

type AddKind = "event" | "task";
type RepeatOption = "never" | "daily" | "weekly" | "monthly" | "yearly";
type DurationOption = "none" | "15" | "30" | "60" | "custom";

const repeatOptions: Array<{ value: RepeatOption; label: string }> = [
  { value: "never", label: "Never" },
  { value: "daily", label: "Daily" },
  { value: "weekly", label: "Weekly" },
  { value: "monthly", label: "Monthly" },
  { value: "yearly", label: "Yearly" },
];

const durationOptions: Array<{ value: DurationOption; label: string }> = [
  { value: "15", label: "15 minutes" },
  { value: "30", label: "30 minutes" },
  { value: "60", label: "1 hour" },
  { value: "custom", label: "Custom end time" },
  { value: "none", label: "No duration" },
];

function eventDatePart(value: string): string {
  if (value.length === 10) return value;
  return localISODate(parseISO(value));
}

function eventTimePart(value: string): string {
  if (value.length === 10) return "09:00";
  return format(parseISO(value), "HH:mm");
}

function recurrenceOption(rule?: string | null): RepeatOption {
  const frequency = rule?.match(/(?:^|;)FREQ=(DAILY|WEEKLY|MONTHLY|YEARLY)(?:;|$)/i)?.[1]?.toLowerCase();
  return frequency === "daily" || frequency === "weekly" || frequency === "monthly" || frequency === "yearly"
    ? frequency
    : "never";
}

function recurrenceRule(option: RepeatOption, date: Date): string | null {
  if (option === "never") return null;
  if (option === "weekly") {
    const weekdays = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
    return `FREQ=WEEKLY;BYDAY=${weekdays[date.getDay()]}`;
  }
  return `FREQ=${option.toUpperCase()}`;
}

function sameEventTime(left?: string | null, right?: string | null): boolean {
  if (!left || !right) return left === right;
  if (left.length === 10 || right.length === 10) return left === right;
  const leftDate = parseISO(left);
  const rightDate = parseISO(right);
  return !Number.isNaN(leftDate.getTime()) && !Number.isNaN(rightDate.getTime())
    ? leftDate.getTime() === rightDate.getTime()
    : left === right;
}

function storedParticipantIDs(event: CalendarEvent | null): Set<string> {
  if (!event) return new Set();
  return new Set([event.assigned_to, ...(event.family_member_ids ?? [])]
    .filter((id): id is string => Boolean(id)));
}

function sameIDs(left?: string[] | null, right?: string[] | null): boolean {
  const normalize = (value?: string[] | null) => [...new Set(value ?? [])].sort();
  return JSON.stringify(normalize(left)) === JSON.stringify(normalize(right));
}

function durationOptionForEvent(event: CalendarEvent | null): DurationOption {
  if (!event) return "15";
  if (!event.end_time || event.all_day) return "none";
  const start = parseISO(event.start_time);
  const end = parseISO(event.end_time);
  const minutes = Math.round((end.getTime() - start.getTime()) / 60_000);
  if (minutes === 15 || minutes === 30 || minutes === 60) return String(minutes) as DurationOption;
  return "custom";
}

function eventAttachments(event: CalendarEvent | null): CalendarEventAttachment[] {
  if (!event) return [];
  if (event.attachments?.length) return event.attachments;
  if (!event.source_document) return [];
  return [{
    ...event.source_document,
    relation_id: `legacy:${event.id}:${event.source_document.id}`,
    role: "other",
    position: 0,
  }];
}

function sameAttachments(
  left: Array<{ document_id: string; role: CalendarEventAttachmentRole }>,
  right: Array<{ document_id: string; role: CalendarEventAttachmentRole }>,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

export function QuickAddDialog({
  open,
  initialKind,
  members,
  onOpenChange,
  onCreated,
  notify,
  initialEvent = null,
  initialDate,
  eventOnly = false,
  recurrenceScope = null,
}: {
  open: boolean;
  initialKind: AddKind;
  members: FamilyMember[];
  onOpenChange: (open: boolean) => void;
  onCreated: () => void;
  notify: (message: string) => void;
  initialEvent?: CalendarEvent | null;
  initialDate?: Date;
  eventOnly?: boolean;
  recurrenceScope?: CalendarRecurrenceMutationScope | null;
}) {
  const [kind, setKind] = useState<AddKind>(initialKind);
  const [title, setTitle] = useState("");
  const [date, setDate] = useState(localISODate(new Date()));
  const [time, setTime] = useState("09:00");
  const [allDay, setAllDay] = useState(false);
  const [allDayMultiDay, setAllDayMultiDay] = useState(false);
  const [allDayEndDate, setAllDayEndDate] = useState(localISODate(new Date()));
  const [duration, setDuration] = useState<DurationOption>("15");
  const [endDate, setEndDate] = useState(localISODate(new Date()));
  const [endTime, setEndTime] = useState("10:00");
  const [repeat, setRepeat] = useState<RepeatOption>("never");
  const [location, setLocation] = useState("");
  const [description, setDescription] = useState("");
  const [attachmentDocumentID, setAttachmentDocumentID] = useState<string | null>(null);
  const [pendingAttachment, setPendingAttachment] = useState<PendingDocumentAttachment | null>(null);
  const [calendarAttachments, setCalendarAttachments] = useState<EventAttachmentSelection[]>([]);
  const [pendingCalendarAttachments, setPendingCalendarAttachments] = useState<PendingEventAttachment[]>([]);
  const uploadedCalendarDocumentIDsRef = useRef<Map<string, string>>(new Map());
  const [attachmentUploadBlocked, setAttachmentUploadBlocked] = useState(false);
  const attachmentDocumentIDRef = useRef<string | null>(null);
  const pendingAttachmentRef = useRef<PendingDocumentAttachment | null>(null);
  const uploadedDocumentIDRef = useRef<string | null>(null);
  const [assignedTo, setAssignedTo] = useState("");
  const [wholeFamily, setWholeFamily] = useState(true);
  const [participantIDs, setParticipantIDs] = useState<Set<string>>(new Set());
  const [affectedMemberIDs, setAffectedMemberIDs] = useState<Set<string>>(new Set());
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [createOperation, setCreateOperation] = useState<{ id: string; fingerprint: string; timestamp: string } | null>(null);
  const [updateOperation, setUpdateOperation] = useState<{ id: string; fingerprint: string; timestamp: string } | null>(null);

  useEffect(() => {
    if (!open) return;
    const baseDate = initialEvent ? parseISO(initialEvent.start_time) : initialDate ?? new Date();
    const defaultEnd = new Date(baseDate.getTime() + 15 * 60 * 1_000);
    setKind(initialEvent || eventOnly ? "event" : initialKind);
    setTitle(initialEvent?.title ?? "");
    setDate(initialEvent ? eventDatePart(initialEvent.start_time) : localISODate(baseDate));
    setTime(initialEvent ? eventTimePart(initialEvent.start_time) : format(baseDate, "HH:mm"));
    setAllDay(initialEvent?.all_day ?? false);
    const startDatePart = initialEvent ? eventDatePart(initialEvent.start_time) : localISODate(baseDate);
    const lastAllDay = initialEvent?.all_day && initialEvent.end_time
      ? localISODate(subDays(parseISO(eventDatePart(initialEvent.end_time)), 1))
      : startDatePart;
    setAllDayMultiDay(lastAllDay > startDatePart);
    setAllDayEndDate(lastAllDay > startDatePart ? lastAllDay : startDatePart);
    setDuration(durationOptionForEvent(initialEvent));
    setEndDate(initialEvent?.end_time ? eventDatePart(initialEvent.end_time) : localISODate(defaultEnd));
    setEndTime(initialEvent?.end_time ? eventTimePart(initialEvent.end_time) : format(defaultEnd, "HH:mm"));
    setRepeat(recurrenceOption(initialEvent?.recurrence_rule));
    setLocation(initialEvent?.location ?? "");
    setDescription(initialEvent?.description ?? "");
    const initialDocumentID = initialEvent?.source_document_id ?? null;
    attachmentDocumentIDRef.current = initialDocumentID;
    pendingAttachmentRef.current = null;
    uploadedDocumentIDRef.current = null;
    setAttachmentDocumentID(initialDocumentID);
    setPendingAttachment(null);
    setCalendarAttachments(eventAttachments(initialEvent).map((attachment) => ({
      documentID: attachment.id,
      role: attachment.role,
    })));
    setPendingCalendarAttachments([]);
    uploadedCalendarDocumentIDsRef.current = new Map();
    setAttachmentUploadBlocked(false);
    setAssignedTo(initialEvent?.assigned_to ?? "");
    const storedParticipants = storedParticipantIDs(initialEvent);
    const initialWholeFamily = !initialEvent
      || storedParticipants.size === 0
      || (members.length > 0 && members.every((member) => storedParticipants.has(member.id)));
    setWholeFamily(initialWholeFamily);
    setParticipantIDs(initialWholeFamily ? new Set() : storedParticipants);
    setAffectedMemberIDs(new Set(initialEvent?.affected_member_ids ?? []));
    setError(null);
    setCreateOperation(null);
    setUpdateOperation(null);
  }, [eventOnly, initialDate, initialEvent, initialKind, members, open]);

  function localStart(nextDate = date, nextTime = time): Date | null {
    const parsed = new Date(`${nextDate}T${nextTime || "09:00"}:00`);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  function localEnd(): Date | null {
    const parsed = new Date(`${endDate}T${endTime}:00`);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  function showEnd(nextEnd: Date) {
    setEndDate(localISODate(nextEnd));
    setEndTime(format(nextEnd, "HH:mm"));
  }

  function moveEndWithStart(nextDate: string, nextTime: string) {
    if (duration === "none") return;
    const nextStart = localStart(nextDate, nextTime);
    if (!nextStart) return;
    if (duration !== "custom") {
      showEnd(new Date(nextStart.getTime() + Number(duration) * 60_000));
      return;
    }
    const previousStart = localStart();
    const previousEnd = localEnd();
    const interval = previousStart && previousEnd && previousEnd > previousStart
      ? previousEnd.getTime() - previousStart.getTime()
      : 15 * 60_000;
    showEnd(new Date(nextStart.getTime() + interval));
  }

  function chooseDuration(next: DurationOption) {
    setDuration(next);
    if (next === "none") return;
    const start = localStart();
    if (!start) return;
    if (next === "custom") {
      const currentEnd = localEnd();
      if (currentEnd && currentEnd > start) return;
      showEnd(new Date(start.getTime() + 15 * 60_000));
      return;
    }
    showEnd(new Date(start.getTime() + Number(next) * 60_000));
  }

  function chooseAllDay(next: boolean) {
    setAllDay(next);
    if (next) {
      setAllDayMultiDay(false);
      setAllDayEndDate(date);
    }
    if (!next && duration === "none") chooseDuration("15");
  }

  function moveAllDayEndWithStart(nextDate: string) {
    if (!nextDate || !date || !allDayEndDate) return;
    const span = Math.max(
      0,
      differenceInCalendarDays(parseISO(allDayEndDate), parseISO(date)),
    );
    setAllDayEndDate(localISODate(addDays(parseISO(nextDate), span)));
  }

  const otherAdults = wholeFamily ? [] : members.filter(
    (member) => member.member_type === "user" && !participantIDs.has(member.id),
  );
  const peopleUnavailable = Boolean(initialEvent && members.length === 0);

  function setEveryone(checked: boolean) {
    setWholeFamily(checked);
    if (checked) {
      setParticipantIDs(new Set());
      setAffectedMemberIDs(new Set());
    }
  }

  function setParticipant(memberID: string, checked: boolean) {
    if (checked) setWholeFamily(false);
    setParticipantIDs((current) => {
      const next = new Set(current);
      if (checked) next.add(memberID);
      else next.delete(memberID);
      return next;
    });
    if (checked) {
      setAffectedMemberIDs((current) => {
        const next = new Set(current);
        next.delete(memberID);
        return next;
      });
    }
  }

  function setAffected(memberID: string, checked: boolean) {
    setAffectedMemberIDs((current) => {
      const next = new Set(current);
      if (checked) next.add(memberID);
      else next.delete(memberID);
      return next;
    });
  }

  async function resolveSourceDocumentID(): Promise<string | null> {
    if (!pendingAttachmentRef.current) return attachmentDocumentIDRef.current;
    if (uploadedDocumentIDRef.current) return uploadedDocumentIDRef.current;
    const uploaded = await uploadPendingDocument(pendingAttachmentRef.current);
    uploadedDocumentIDRef.current = uploaded.id;
    attachmentDocumentIDRef.current = uploaded.id;
    setAttachmentDocumentID(uploaded.id);
    return uploaded.id;
  }

  async function resolveCalendarAttachments(): Promise<Array<{
    document_id: string;
    role: CalendarEventAttachmentRole;
  }>> {
    const uploaded: Array<{ document_id: string; role: CalendarEventAttachmentRole }> = [];
    for (const item of pendingCalendarAttachments) {
      let documentID = uploadedCalendarDocumentIDsRef.current.get(item.pending.documentID);
      if (!documentID) {
        const document = await uploadPendingDocument(item.pending);
        documentID = document.id;
        uploadedCalendarDocumentIDsRef.current.set(item.pending.documentID, document.id);
      }
      uploaded.push({ document_id: documentID, role: item.role });
    }
    return [
      ...calendarAttachments.map((item) => ({
        document_id: item.documentID,
        role: item.role,
      })),
      ...uploaded,
    ];
  }

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const cleanTitle = title.trim();
    if (!cleanTitle) {
      setError("Add a title first.");
      return;
    }
    setSubmitting(true);
    setError(null);
    try {
      if (kind === "event") {
        if (members.length > 0 && !wholeFamily && participantIDs.size === 0) {
          setError("Choose at least one person who is going.");
          return;
        }
        const startDate = new Date(`${date}T${time || "09:00"}:00`);
        const startValue = allDay ? date : localISODateTime(startDate);
        const parsedEnd = duration !== "none" && !allDay ? new Date(`${endDate}T${endTime}:00`) : null;
        if (parsedEnd && parsedEnd <= startDate) {
          setError("The end time must be after the start time.");
          return;
        }
        if (allDay && allDayMultiDay && allDayEndDate < date) {
          setError("The last day must not be before the first day.");
          return;
        }
        const endValue = allDay && allDayMultiDay
          ? localISODate(addDays(parseISO(allDayEndDate), 1))
          : parsedEnd ? localISODateTime(parsedEnd) : null;
        const cleanDescription = description.trim() || null;
        const cleanLocation = location.trim() || null;
        const nextRule = recurrenceRule(repeat, startDate);
        const selectedParticipants = members
          .filter((member) => participantIDs.has(member.id))
          .map((member) => member.id);
        const storeAsWholeFamily = wholeFamily
          || members.length === 0
          || selectedParticipants.length === members.length;
        const familyMemberIDs = storeAsWholeFamily ? null : selectedParticipants;
        const eventAssignedTo = familyMemberIDs?.length === 1 ? familyMemberIDs[0] : null;
        const affectedIDs = members
          .filter((member) => member.member_type === "user"
            && affectedMemberIDs.has(member.id)
            && !participantIDs.has(member.id))
          .map((member) => member.id);
        const affectedPayload = affectedIDs.length ? affectedIDs : null;
        const resolvedAttachments = await resolveCalendarAttachments();
        const sourceDocumentID = resolvedAttachments[0]?.document_id ?? null;

        if (initialEvent) {
          const updates: Record<string, unknown> = {};
          const startChanged = !sameEventTime(startValue, initialEvent.start_time);
          const previousRepeat = recurrenceOption(initialEvent.recurrence_rule);
          if (cleanTitle !== initialEvent.title) updates.title = cleanTitle;
          if (cleanDescription !== (initialEvent.description ?? null)) updates.description = cleanDescription;
          if (startChanged) updates.start_time = startValue;
          if (!sameEventTime(endValue, initialEvent.end_time ?? null)) updates.end_time = endValue;
          if (allDay !== initialEvent.all_day) updates.all_day = allDay;
          if (recurrenceScope !== "only_this" && repeat !== previousRepeat) {
            updates.recurrence_rule = nextRule;
          } else if (
            recurrenceScope !== "only_this"
            && startChanged
            && repeat === "weekly"
            && /^FREQ=WEEKLY;BYDAY=[A-Z]{2}$/i.test(initialEvent.recurrence_rule ?? "")
          ) {
            updates.recurrence_rule = nextRule;
          }
          if (cleanLocation !== (initialEvent.location ?? null)) updates.location = cleanLocation;
          const initialAttachments = eventAttachments(initialEvent).map((item) => ({
            document_id: item.id,
            role: item.role,
          }));
          if (!sameAttachments(resolvedAttachments, initialAttachments)) {
            updates.attachments = resolvedAttachments;
            updates.source_document_id = sourceDocumentID;
          }
          if (!peopleUnavailable) {
            const initialParticipants = storedParticipantIDs(initialEvent);
            const initialWholeFamily = initialParticipants.size === 0
              || members.every((member) => initialParticipants.has(member.id));
            const initialFamilyMemberIDs = initialWholeFamily
              ? null
              : members.filter((member) => initialParticipants.has(member.id)).map((member) => member.id);
            const initialAssignedTo = initialFamilyMemberIDs?.length === 1 ? initialFamilyMemberIDs[0] : null;
            if (!sameIDs(familyMemberIDs, initialFamilyMemberIDs)
              || eventAssignedTo !== initialAssignedTo
              || !sameIDs(affectedPayload, initialEvent.affected_member_ids)) {
              updates.assigned_to = eventAssignedTo;
              updates.family_member_ids = familyMemberIDs;
              updates.affected_member_ids = affectedPayload;
            }
          }
          if (Object.keys(updates).length) {
            const eventID = initialEvent.series_id ?? initialEvent.id;
            const generatedOccurrence = initialEvent.is_generated_occurrence === true
              && Boolean(initialEvent.series_id);
            if (generatedOccurrence && !recurrenceScope) {
              setError("Choose which repeating events to edit.");
              return;
            }
            const fingerprint = JSON.stringify({
              eventID,
              recurrenceScope,
              occurrenceStart: initialEvent.start_time,
              ...updates,
            });
            const operation = updateOperation?.fingerprint === fingerprint
              ? updateOperation
              : { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
            setUpdateOperation(operation);
            const updatePayload = {
              ...updates,
              client_id: operation.id,
              client_timestamp: operation.timestamp,
            };
            if (generatedOccurrence) {
              await api(`/calendar/${eventID}/occurrences/edit`, {
                method: "POST",
                body: JSON.stringify({
                  scope: recurrenceScope,
                  occurrence_start: initialEvent.start_time,
                  updates: updatePayload,
                }),
              }, true, false);
            } else {
              await api(`/calendar/${eventID}`, {
                method: "PUT",
                body: JSON.stringify(updatePayload),
              });
            }
            setUpdateOperation(null);
          }
          notify(recurrenceScope ? "Repeating event updated." : initialEvent.recurrence_rule ? "Repeating event updated." : "Event updated.");
        } else {
          const createPayload = {
            title: cleanTitle,
            description: cleanDescription,
            start_time: startValue,
            end_time: endValue,
            all_day: allDay,
            recurrence_rule: nextRule,
            location: cleanLocation,
            assigned_to: eventAssignedTo,
            family_member_ids: familyMemberIDs,
            affected_member_ids: affectedPayload,
            source_document_id: sourceDocumentID,
            attachments: resolvedAttachments,
          };
          const fingerprint = JSON.stringify({ kind: "event", ...createPayload });
          const operation = createOperation?.fingerprint === fingerprint
            ? createOperation
            : { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
          setCreateOperation(operation);
          await api("/calendar/", {
            method: "POST",
            body: JSON.stringify({
              id: operation.id,
              ...createPayload,
              client_id: operation.id,
              client_timestamp: operation.timestamp,
            }),
          });
          setCreateOperation(null);
          notify("Added to the family calendar.");
        }
      } else {
        const due = date ? localISODateTime(new Date(`${date}T${time}:00`)) : null;
        const sourceDocumentID = await resolveSourceDocumentID();
        const createPayload = {
          title: cleanTitle,
          due_date: due,
          assigned_to: assignedTo || null,
          category: "other",
          priority: 2,
          source_document_id: sourceDocumentID,
        };
        const fingerprint = JSON.stringify({ kind: "task", ...createPayload });
        const operation = createOperation?.fingerprint === fingerprint
          ? createOperation
          : { id: crypto.randomUUID(), fingerprint, timestamp: new Date().toISOString() };
        setCreateOperation(operation);
        await api("/tasks/", {
          method: "POST",
          body: JSON.stringify({
            id: operation.id,
            ...createPayload,
            client_id: operation.id,
            client_timestamp: operation.timestamp,
          }),
        });
        setCreateOperation(null);
        notify("Task created.");
      }
      onOpenChange(false);
      onCreated();
    } catch (requestError) {
      setError(requestError instanceof Error ? requestError.message : "Couldn't save that item.");
    } finally {
      setSubmitting(false);
    }
  }

  const isEditingSeries = Boolean(initialEvent?.recurrence_rule || initialEvent?.series_id);
  const recurrenceDescription = recurrenceScope === "only_this"
    ? "Other events in the series stay unchanged."
    : recurrenceScope === "this_and_later"
      ? "Earlier events stay unchanged. This event starts a new series."
      : recurrenceScope === "entire_series"
        ? "Your changes apply to every event in the series."
        : null;
  const recurrenceLabel = recurrenceScope === "only_this"
    ? "Only this event"
    : recurrenceScope === "this_and_later"
      ? "This and later events"
      : recurrenceScope === "entire_series"
        ? "Every event in series"
        : null;

  return (
    <Modal
      open={open}
      onOpenChange={onOpenChange}
      title={initialEvent ? "Edit event" : "Add to the plan"}
      description={recurrenceDescription ?? (isEditingSeries ? "Choose how this repeating event changes." : "Create one clear item for the family.")}
      size={kind === "event" ? "wide" : "default"}
    >
      <form className="form-stack event-editor-form" onSubmit={submit} aria-busy={submitting}>
        {!eventOnly && !initialEvent ? (
          <Segmented
            value={kind}
            onChange={setKind}
            label="Item type"
            options={[
              { value: "event", label: "Event" },
              { value: "task", label: "Task" },
            ]}
          />
        ) : null}
        {error ? <div className="form-error" role="alert">{error}</div> : null}
        {recurrenceLabel ? (
          <div className="form-warning" role="status">
            <strong>{recurrenceLabel}</strong>
            <span>{recurrenceDescription}</span>
          </div>
        ) : null}
        <div className="field">
          <label htmlFor="quick-title">Title</label>
          <input
            id="quick-title"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder={kind === "event" ? "Football practice" : "Return nursery form"}
            maxLength={300}
            required
          />
        </div>

        {kind === "event" ? (
          <>
            <fieldset className="event-editor-primary-group">
              <legend>When</legend>
              <label className="check-row" htmlFor="quick-all-day"><input id="quick-all-day" type="checkbox" checked={allDay} onChange={(event) => chooseAllDay(event.target.checked)} /><span>All-day event</span></label>
              <div className="form-grid event-date-grid"><div className="field"><label htmlFor="quick-date">Date</label><input id="quick-date" type="date" value={date} onChange={(event) => { const nextDate = event.target.value; if (allDay) moveAllDayEndWithStart(nextDate); else moveEndWithStart(nextDate, time); setDate(nextDate); }} required /></div>{!allDay ? <div className="field"><label htmlFor="quick-time">Starts</label><input id="quick-time" type="time" value={time} onChange={(event) => { const nextTime = event.target.value; moveEndWithStart(date, nextTime); setTime(nextTime); }} required /></div> : null}</div>
              {allDay ? <><label className="check-row" htmlFor="quick-multi-day"><input id="quick-multi-day" type="checkbox" checked={allDayMultiDay} onChange={(event) => { setAllDayMultiDay(event.target.checked); if (event.target.checked && allDayEndDate < date) setAllDayEndDate(date); }} /><span>Multi-day</span></label>{allDayMultiDay ? <div className="field"><label htmlFor="quick-last-day">Last day</label><input id="quick-last-day" type="date" min={date} value={allDayEndDate} onChange={(event) => setAllDayEndDate(event.target.value)} required /></div> : null}</> : <><div className="field"><label htmlFor="quick-duration">Duration (optional)</label><select id="quick-duration" value={duration} onChange={(event) => chooseDuration(event.target.value as DurationOption)}>{durationOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></div>{duration !== "none" ? <div className="form-grid event-date-grid"><div className="field"><label htmlFor="quick-end-date">End date</label><input id="quick-end-date" type="date" min={date} value={endDate} onChange={(event) => { setDuration("custom"); setEndDate(event.target.value); }} required /></div><div className="field"><label htmlFor="quick-end-time">Ends</label><input id="quick-end-time" type="time" value={endTime} onChange={(event) => { setDuration("custom"); setEndTime(event.target.value); }} required /></div></div> : null}</>}
            </fieldset>

            {peopleUnavailable ? <div className="form-warning" role="status">Family members could not be loaded. Existing people will be kept.</div> : null}
            <fieldset className="event-people-fieldset event-editor-primary-group" disabled={peopleUnavailable}><legend>Who is going?</legend><div className="event-people-options"><label className="check-row" htmlFor="quick-person-everyone"><input id="quick-person-everyone" type="checkbox" checked={wholeFamily} onChange={(event) => setEveryone(event.target.checked)} /><span>Everyone</span></label>{members.map((member) => <label className="check-row" htmlFor={`quick-person-${member.id}`} key={member.id}><input id={`quick-person-${member.id}`} type="checkbox" checked={participantIDs.has(member.id)} onChange={(event) => setParticipant(member.id, event.target.checked)} /><span>{member.name}</span></label>)}</div></fieldset>

            <details className="event-editor-more">
              <summary><span>More</span><small>Repeat, location, notes, coverage and documents</small></summary>
              <div className="form-stack">
                {recurrenceScope === "only_this" ? <div className="field"><span className="field-label">Repeat</span><span>Only this event</span></div> : <div className="field"><label htmlFor="quick-repeat">Repeat</label><select id="quick-repeat" value={repeat} onChange={(event) => setRepeat(event.target.value as RepeatOption)}>{repeatOptions.map((option) => <option value={option.value} key={option.value}>{option.label}</option>)}</select></div>}
                <div className="field"><label htmlFor="quick-location">Location (optional)</label><input id="quick-location" value={location} maxLength={300} onChange={(event) => setLocation(event.target.value)} /></div>
                {otherAdults.length ? <fieldset className="event-people-fieldset event-affected-fieldset"><legend>Coverage</legend><div className="event-people-options">{otherAdults.map((member) => <label className="check-row" htmlFor={`quick-affected-${member.id}`} key={member.id}><input id={`quick-affected-${member.id}`} type="checkbox" checked={affectedMemberIDs.has(member.id)} onChange={(event) => setAffected(member.id, event.target.checked)} /><span>Affects {member.name} too</span></label>)}</div><small>Include adults whose availability or family cover changes.</small></fieldset> : null}
                <div className="field"><label htmlFor="quick-description">Notes (optional)</label><textarea id="quick-description" rows={3} value={description} maxLength={2_000} onChange={(event) => setDescription(event.target.value)} /></div>
                <EventDocumentAttachmentsField active={open} currentAttachments={eventAttachments(initialEvent)} selections={calendarAttachments} pending={pendingCalendarAttachments} disabled={submitting} onSelectionsChange={setCalendarAttachments} onPendingChange={setPendingCalendarAttachments} />
              </div>
            </details>
          </>
        ) : (
          <>
            <div className="form-grid">
              <div className="field"><label htmlFor="quick-date">Due date</label><input id="quick-date" type="date" value={date} onChange={(event) => setDate(event.target.value)} /></div>
              <div className="field"><label htmlFor="quick-time">Time</label><input id="quick-time" type="time" value={time} onChange={(event) => setTime(event.target.value)} /></div>
            </div>
            <div className="field"><label htmlFor="quick-person">For</label><select id="quick-person" value={assignedTo} onChange={(event) => setAssignedTo(event.target.value)}><option value="">Whole family</option>{members.map((member) => <option key={member.id} value={member.id}>{member.name}</option>)}</select></div>
          </>
        )}

        {kind === "task" ? (
          <DocumentAttachmentField
            active={open}
            idPrefix="quick-add"
            currentDocument={null}
            selectedDocumentID={attachmentDocumentID}
            pending={pendingAttachment}
            disabled={submitting}
            onSelect={(documentID) => {
              attachmentDocumentIDRef.current = documentID;
              pendingAttachmentRef.current = null;
              uploadedDocumentIDRef.current = null;
              setAttachmentDocumentID(documentID);
              setPendingAttachment(null);
            }}
            onPending={(nextPending) => {
              if (!nextPending) {
                attachmentDocumentIDRef.current = null;
                setAttachmentDocumentID(null);
              }
              pendingAttachmentRef.current = nextPending;
              uploadedDocumentIDRef.current = null;
              setPendingAttachment(nextPending);
            }}
            onUploadBlockedChange={setAttachmentUploadBlocked}
          />
        ) : null}

        <div className="dialog-actions">
          <button type="button" className="button button--secondary" onClick={() => onOpenChange(false)}>Cancel</button>
          <button type="submit" className="button button--primary" disabled={submitting || attachmentUploadBlocked} aria-describedby={attachmentUploadBlocked ? "quick-add-attachment-offline" : undefined}>
            {submitting ? <LoaderCircle className="spin" aria-hidden="true" size={17} /> : null}
            {submitting ? "Saving…" : initialEvent ? "Save changes" : kind === "event" ? "Add event" : "Create task"}
          </button>
        </div>
      </form>
    </Modal>
  );
}
