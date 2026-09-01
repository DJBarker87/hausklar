import { AlertCircle, CalendarCheck2, Gauge, PiggyBank, Repeat2, ShoppingBag, Target } from "lucide-react";
import { useEffect, useMemo, useRef, useState, type FormEvent } from "react";

import { api } from "../api";
import { getFinanceAdultStrings } from "../financeAdultStrings";
import { todayInTimeZone } from "../financeDate";
import type { FinanceLocale } from "../financeStrings";
import type { FinanceAccount, FinanceAnalysisRequest, FinanceAnalysisResponse, FinanceForecast, FinanceGoal, FinanceHabit, FinancePaydayAction, FinancePlan, FinancePlanAnswerBasis, FinancePlanEffortLevel, FinancePlanSet, FinancePurchaseEvaluation, FinancePurchaseProposal, FinancePurchaseScenario, FinanceSettings, FinanceSpace } from "../types";
import { cn } from "../components/ui";

type LoadState = "loading" | "ready" | "error";
type WorkKind = "" | "generate" | "activate" | "payday" | "habit" | "purchase" | "approve";

function isAbortError(error: unknown) {
  return error instanceof DOMException && error.name === "AbortError";
}

function errorStatus(error: unknown) {
  if (!error || typeof error !== "object" || !("status" in error)) return null;
  return typeof error.status === "number" ? error.status : null;
}

function amountToMinor(value: string) {
  const normalized = value.trim().replace(",", ".");
  if (!/^(?:0|[1-9]\d*)(?:\.\d{1,2})?$/.test(normalized)) return null;
  const [whole, fraction = ""] = normalized.split(".");
  const result = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  return Number.isSafeInteger(result) ? result : null;
}

function formatCurrency(minor: number, currency: string, locale: FinanceLocale) {
  return new Intl.NumberFormat(locale === "de" ? "de-DE" : "en-GB", { style: "currency", currency }).format(minor / 100);
}

function formatDate(value: string, locale: FinanceLocale) {
  const date = new Date(`${value}T12:00:00Z`);
  return Number.isNaN(date.valueOf()) ? value : new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", { dateStyle: "medium", timeZone: "UTC" }).format(date);
}

function formatDateTime(value: string, locale: FinanceLocale) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? value : new Intl.DateTimeFormat(locale === "de" ? "de-DE" : "en-GB", { dateStyle: "medium", timeStyle: "short" }).format(date);
}

function addDays(value: string, days: number) {
  const date = new Date(`${value}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function addMonths(value: string, months: number) {
  const date = new Date(`${value}T12:00:00Z`);
  if (Number.isNaN(date.valueOf())) return value;
  date.setUTCMonth(date.getUTCMonth() + months);
  return date.toISOString().slice(0, 10);
}

function latestPlanGroup(plans: FinancePlan[]) {
  const latest = [...plans].sort((left, right) => right.version - left.version || right.created_at.localeCompare(left.created_at))[0];
  return latest ? plans.filter((plan) => plan.proposal_group_id === latest.proposal_group_id) : [];
}

function effortLevel(plan: FinancePlan): FinancePlanEffortLevel {
  if (plan.effort_level) return plan.effort_level;
  if (plan.strategy === "MINIMAL_DISRUPTION") return "EASY";
  if (plan.strategy === "AGGRESSIVE") return "HARD";
  return "MEDIUM";
}

function threeTierChoices(plans: FinancePlan[], recommendedStrategy: FinancePlan["strategy"] | null) {
  const choices = new Map<FinancePlanEffortLevel, FinancePlan>();
  const preferred = [...plans].sort((left, right) => {
    const leftRank = left.status === "ACTIVE" ? 0 : left.strategy === recommendedStrategy ? 1 : 2;
    const rightRank = right.status === "ACTIVE" ? 0 : right.strategy === recommendedStrategy ? 1 : 2;
    return leftRank - rightRank;
  });
  preferred.forEach((plan) => {
    const tier = effortLevel(plan);
    if (!choices.has(tier)) choices.set(tier, plan);
  });
  return (["EASY", "MEDIUM", "HARD"] as const)
    .map((tier) => choices.get(tier) ?? null)
    .filter((plan): plan is FinancePlan => plan !== null);
}

function activePlansByGoal(plans: FinancePlan[]) {
  const active = [...plans]
    .filter((plan) => plan.status === "ACTIVE")
    .sort((left, right) => (
      (right.activated_at ?? right.created_at).localeCompare(left.activated_at ?? left.created_at)
      || right.version - left.version
    ));
  const byGoal = new Map<string, FinancePlan>();
  active.forEach((plan) => {
    if (!byGoal.has(plan.goal_id)) byGoal.set(plan.goal_id, plan);
  });
  return byGoal;
}

function monthsUntil(deadline: string, from: string) {
  const end = new Date(`${deadline}T12:00:00Z`);
  const start = new Date(`${from}T12:00:00Z`);
  if (Number.isNaN(end.valueOf()) || Number.isNaN(start.valueOf())) return 1;
  const wholeMonths = (end.getUTCFullYear() - start.getUTCFullYear()) * 12 + end.getUTCMonth() - start.getUTCMonth();
  return Math.max(1, wholeMonths + (end.getUTCDate() >= start.getUTCDate() ? 1 : 0));
}

type GoalField = "name" | "target" | "deadline" | "allocated";
type GoalErrors = Partial<Record<GoalField, string>>;

export type FinanceMonthlySummary = {
  period_start: string;
  period_end: string;
  data_through: string | null;
  currencies: Array<{
    currency: string;
    income_minor: number;
    spending_minor: number;
    saved_minor: number;
  }>;
};

const emptyAnalysisFilters: FinanceAnalysisRequest["filters"] = {
  account_ids: [],
  merchants: [],
  categories: [],
  transaction_types: [],
  line_kinds: [],
  normalized_items: [],
  purposes: [],
  beneficiaries: [],
  plannedness: [],
  utilities: [],
  decision_qualities: [],
  value_for_money: [],
  outcomes: [],
  itemisation: [],
};

function firstDayOfMonth(value: string) {
  return `${value.slice(0, 7)}-01`;
}

function exactMinor(response: FinanceAnalysisResponse) {
  if (!response.total.denominator) return 0;
  return Math.round(response.total.numerator / response.total.denominator);
}

async function loadMonthlySummary({
  spaces,
  accounts,
  monthlySpaceIDs,
  today,
  signal,
}: {
  spaces: FinanceSpace[];
  accounts: FinanceAccount[];
  monthlySpaceIDs: string[];
  today: string;
  signal: AbortSignal;
}): Promise<FinanceMonthlySummary> {
  const allowedMonthlySpaces = new Set(monthlySpaceIDs);
  const inputs = spaces.flatMap((space) => {
    if (!allowedMonthlySpaces.has(space.id)) return [];
    const currencies = [...new Set(accounts
      .filter((account) => account.space_id === space.id)
      .map((account) => account.currency))].sort();
    return currencies.map((currency) => ({ spaceID: space.id, currency }));
  });
  const periodStart = firstDayOfMonth(today);
  const results = await Promise.all(inputs.map(async ({ spaceID, currency }) => {
    const base: Omit<FinanceAnalysisRequest, "measure"> = {
      space_id: spaceID,
      basis: "TRANSACTIONS",
      start_date: periodStart,
      end_date: today,
      currency,
      grouping: "TOTAL",
      comparison: "NONE",
      pending_policy: "EXCLUDE",
      refund_policy: "NET",
      transfer_policy: "EXCLUDE",
      filters: emptyAnalysisFilters,
      save_as: null,
    };
    const [income, spending] = await Promise.all([
      api<FinanceAnalysisResponse>("/finance/analysis", { method: "POST", signal, body: JSON.stringify({ ...base, measure: "INCOME" }) }, true, false),
      api<FinanceAnalysisResponse>("/finance/analysis", { method: "POST", signal, body: JSON.stringify({ ...base, measure: "SPEND" }) }, true, false),
    ]);
    return {
      currency,
      incomeMinor: exactMinor(income),
      spendingMinor: exactMinor(spending),
      dataThrough: [income.data_through, spending.data_through].filter((value): value is string => Boolean(value)).sort().at(-1) ?? null,
    };
  }));
  const currencies = new Map<string, FinanceMonthlySummary["currencies"][number]>();
  results.forEach((result) => {
    const current = currencies.get(result.currency) ?? { currency: result.currency, income_minor: 0, spending_minor: 0, saved_minor: 0 };
    current.income_minor += result.incomeMinor;
    current.spending_minor += result.spendingMinor;
    current.saved_minor = current.income_minor - current.spending_minor;
    currencies.set(result.currency, current);
  });
  return {
    period_start: periodStart,
    period_end: today,
    data_through: results.map((result) => result.dataThrough).filter((value): value is string => Boolean(value)).sort().at(-1) ?? null,
    currencies: [...currencies.values()].sort((left, right) => left.currency.localeCompare(right.currency)),
  };
}

export function FinancePlansView({
  spaces,
  accounts,
  goals,
  monthlySummary: suppliedMonthlySummary,
  monthlySpaceIDs,
  locale,
  showDeepTools = true,
}: {
  spaces: FinanceSpace[];
  accounts: FinanceAccount[];
  goals: FinanceGoal[];
  monthlySummary?: FinanceMonthlySummary;
  monthlySpaceIDs?: string[];
  locale: FinanceLocale;
  showDeepTools?: boolean;
}) {
  const copy = getFinanceAdultStrings(locale).plans;
  const text = (english: string, german: string) => locale === "de" ? german : english;
  const [state, setState] = useState<LoadState>("loading");
  const [retryKey, setRetryKey] = useState(0);
  const [plans, setPlans] = useState<FinancePlan[]>([]);
  const [actions, setActions] = useState<FinancePaydayAction[]>([]);
  const [habits, setHabits] = useState<FinanceHabit[]>([]);
  const [proposals, setProposals] = useState<FinancePurchaseProposal[]>([]);
  const [householdToday, setHouseholdToday] = useState("");
  const [monthlySummary, setMonthlySummary] = useState<FinanceMonthlySummary | null>(suppliedMonthlySummary ?? null);
  const [goalID, setGoalID] = useState("");
  const [createSpaceID, setCreateSpaceID] = useState(spaces[0]?.id ?? "");
  const [localGoals, setLocalGoals] = useState(goals);
  const [newGoalOpen, setNewGoalOpen] = useState(false);
  const [planOptionsOpen, setPlanOptionsOpen] = useState(false);
  const [newGoal, setNewGoal] = useState({ name: "", target: "", deadline: "", allocated: "" });
  const [goalErrors, setGoalErrors] = useState<GoalErrors>({});
  const goalNameRef = useRef<HTMLInputElement>(null);
  const goalTargetRef = useRef<HTMLInputElement>(null);
  const goalDeadlineRef = useRef<HTMLInputElement>(null);
  const goalAllocatedRef = useRef<HTMLInputElement>(null);
  const [recommendations, setRecommendations] = useState<Record<string, FinancePlan["strategy"]>>({});
  const [pendingPlan, setPendingPlan] = useState<FinancePlan | null>(null);
  const [work, setWork] = useState<WorkKind>("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [sourceAccountID, setSourceAccountID] = useState("");
  const [destinationAccountID, setDestinationAccountID] = useState("");
  const [resolution, setResolution] = useState<Record<string, { status: "DONE" | "SKIPPED" | "CHANGED"; changed: string; note: string }>>({});
  const [habitReview, setHabitReview] = useState<Record<string, { decision: "KEEP" | "ADJUST" | "STOP"; friction: string; note: string }>>({});
  const [purchase, setPurchase] = useState({ name: "", amount: "", desiredDate: "", accountID: "", purpose: "", beneficiary: "", laterDate: "" });
  const [evaluation, setEvaluation] = useState<FinancePurchaseEvaluation | null>(null);
  const selectionKey = spaces.map((space) => space.id).join(":");
  const accountKey = accounts.map((account) => `${account.id}:${account.space_id}:${account.currency}`).join(":");
  const monthlySpaceKey = (monthlySpaceIDs ?? spaces.map((space) => space.id)).join(":");
  const allowedSpaceIDs = useMemo(() => new Set(spaces.map((space) => space.id)), [selectionKey]);
  const visibleGoals = localGoals.filter((goal) => allowedSpaceIDs.has(goal.space_id) && goal.status === "ACTIVE");
  const visibleGoalKey = visibleGoals.map((goal) => `${goal.space_id}:${goal.id}`).join(":");
  const selectedGoal = visibleGoals.find((goal) => goal.id === goalID) ?? null;
  const spaceID = selectedGoal?.space_id ?? (allowedSpaceIDs.has(createSpaceID) ? createSpaceID : spaces[0]?.id ?? "");
  const spaceAccounts = accounts.filter((account) => account.space_id === spaceID);
  const paydaySources = spaceAccounts.filter((account) => account.include_in_cashflow && account.balance !== null && ["CURRENT", "CASH"].includes(account.account_type) && account.purpose === "OPERATING_CURRENT");
  const paydayDestinations = spaceAccounts.filter((account) => account.include_in_cashflow && ["SAVINGS", "GOAL"].includes(account.purpose));
  const purchaseAccounts = paydaySources;
  const purchaseCurrency = purchaseAccounts.find((account) => account.id === purchase.accountID)?.currency
    ?? purchaseAccounts[0]?.currency
    ?? "";
  const activePlanLookup = activePlansByGoal(plans);
  const activePlan = selectedGoal ? activePlanLookup.get(selectedGoal.id) ?? null : null;
  const latestChoices = latestPlanGroup(plans.filter((plan) => !goalID || plan.goal_id === goalID));
  const recommendedStrategy = latestChoices[0] ? recommendations[latestChoices[0].proposal_group_id] ?? null : null;
  const planChoices = threeTierChoices(latestChoices, recommendedStrategy);
  const recommendedPlan = planChoices.find((plan) => effortLevel(plan) === "MEDIUM") ?? null;
  const evaluatedProposal = evaluation ? proposals.find((proposal) => proposal.id === evaluation.proposal_id) ?? null : null;

  function planMoney(plan: FinancePlan, minor: number) {
    return formatCurrency(minor, plan.currency, locale);
  }

  function requiredMonthly(plan: FinancePlan, goal: FinanceGoal | null) {
    if (typeof plan.required_monthly_minor === "number" && (plan.required_monthly_minor > 0 || !goal || goal.remaining_minor <= 0)) return plan.required_monthly_minor;
    if (!goal) return Math.max(0, plan.required_reduction_minor);
    return Math.ceil(Math.max(0, goal.remaining_minor) / monthsUntil(goal.deadline, householdToday || goal.created_at.slice(0, 10)));
  }

  function plannedMonthly(plan: FinancePlan) {
    return Math.max(0, plan.planned_monthly_saving_minor ?? plan.monthly_change_minor);
  }

  function targetShortfall(plan: FinancePlan) {
    return Math.max(0, plan.goal_shortfall_at_target_minor ?? plan.shortfall_minor);
  }

  function expectedAtTarget(plan: FinancePlan, goal: FinanceGoal | null) {
    if (typeof plan.projected_amount_at_target_minor === "number") return plan.projected_amount_at_target_minor;
    if (!goal) return 0;
    return Math.max(goal.currently_allocated_minor, goal.target_minor - targetShortfall(plan));
  }

  function projectedFinish(plan: FinancePlan, goal: FinanceGoal | null) {
    if (plan.supported_goal_date) return plan.supported_goal_date;
    if (!goal || !householdToday) return plan.target_date;
    const monthly = plannedMonthly(plan);
    if (monthly <= 0) return plan.target_date;
    return addMonths(householdToday, Math.ceil(Math.max(0, goal.remaining_minor) / monthly));
  }

  function answerBasis(plan: FinancePlan): FinancePlanAnswerBasis {
    return plan.answer_basis ?? "ESTIMATED";
  }

  useEffect(() => {
    setCreateSpaceID((current) => allowedSpaceIDs.has(current) ? current : spaces[0]?.id ?? "");
    setGoalID((current) => visibleGoals.some((goal) => goal.id === current) ? current : visibleGoals[0]?.id ?? "");
  }, [selectionKey, visibleGoalKey]);

  useEffect(() => {
    setLocalGoals(goals);
  }, [goals]);

  useEffect(() => {
    if (!spaces.length) return;
    const controller = new AbortController();
    let active = true;
    setState("loading");
    setError("");
    const settingsRequest = api<FinanceSettings>("/finance/settings", { signal: controller.signal }, true, false)
      .catch(() => ({ household_timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC" } as FinanceSettings));
    const bundleRequest = Promise.all(spaces.map(async (space) => {
      const encodedSpaceID = encodeURIComponent(space.id);
      const [loadedPlans, loadedActions, loadedHabits, loadedProposals] = await Promise.all([
        api<FinancePlan[]>(`/finance/plans?space_id=${encodedSpaceID}&include_inactive=true`, { signal: controller.signal }, true, false).catch(() => []),
        api<FinancePaydayAction[]>(`/finance/payday-actions?space_id=${encodedSpaceID}&include_resolved=true`, { signal: controller.signal }, true, false).catch(() => []),
        showDeepTools ? api<FinanceHabit[]>(`/finance/habits?space_id=${encodedSpaceID}&include_inactive=true`, { signal: controller.signal }, true, false).catch(() => []) : Promise.resolve([]),
        showDeepTools ? api<FinancePurchaseProposal[]>(`/finance/proposals?space_id=${encodedSpaceID}&include_resolved=true`, { signal: controller.signal }, true, false).catch(() => []) : Promise.resolve([]),
      ]);
      return {
        plans: loadedPlans.filter((item) => item.space_id === space.id),
        actions: loadedActions.filter((item) => item.space_id === space.id),
        habits: loadedHabits.filter((item) => item.space_id === space.id),
        proposals: loadedProposals.filter((item) => item.space_id === space.id),
      };
    }));
    const monthRequest = suppliedMonthlySummary
      ? Promise.resolve(suppliedMonthlySummary)
      : settingsRequest.then((settings) => {
        const today = todayInTimeZone(settings.household_timezone);
        return loadMonthlySummary({
          spaces,
          accounts,
          monthlySpaceIDs: monthlySpaceIDs ?? spaces.map((space) => space.id),
          today,
          signal: controller.signal,
        }).catch(() => ({ period_start: firstDayOfMonth(today), period_end: today, data_through: null, currencies: [] }));
      });
    Promise.all([settingsRequest, bundleRequest, monthRequest])
      .then(([settings, bundles, loadedMonth]) => {
        if (!active) return;
        const today = todayInTimeZone(settings.household_timezone);
        setHouseholdToday(today);
        setPlans(bundles.flatMap((bundle) => bundle.plans));
        setActions(bundles.flatMap((bundle) => bundle.actions));
        setHabits(bundles.flatMap((bundle) => bundle.habits));
        setProposals(bundles.flatMap((bundle) => bundle.proposals));
        setMonthlySummary(loadedMonth);
        setGoalID((current) => visibleGoals.some((goal) => goal.id === current) ? current : visibleGoals[0]?.id ?? "");
        setPurchase((current) => ({ ...current, desiredDate: current.desiredDate || today }));
        setState("ready");
      })
      .catch((caught: unknown) => {
        if (!active || isAbortError(caught)) return;
        setState("error");
      });
    return () => {
      active = false;
      controller.abort();
    };
  }, [selectionKey, accountKey, monthlySpaceKey, suppliedMonthlySummary, showDeepTools, retryKey]);

  useEffect(() => {
    const sources = accounts.filter((account) => account.space_id === spaceID && account.include_in_cashflow && account.balance !== null && ["CURRENT", "CASH"].includes(account.account_type) && account.purpose === "OPERATING_CURRENT");
    const destinations = accounts.filter((account) => account.space_id === spaceID && account.include_in_cashflow && ["SAVINGS", "GOAL"].includes(account.purpose));
    setSourceAccountID((current) => sources.some((account) => account.id === current) ? current : sources[0]?.id ?? "");
    setDestinationAccountID((current) => destinations.some((account) => account.id === current) ? current : destinations[0]?.id ?? "");
    setPurchase((current) => ({ ...current, accountID: sources.some((account) => account.id === current.accountID) ? current.accountID : sources[0]?.id ?? "" }));
  }, [spaceID, accounts]);

  function clearMessages() {
    setError("");
    setNotice("");
  }

  async function generatePlans() {
    if (!selectedGoal || work) return;
    const goalSpaceID = selectedGoal.space_id;
    clearMessages();
    setWork("generate");
    try {
      const generated = await api<FinancePlanSet>(
        `/finance/plans/generate?space_id=${encodeURIComponent(goalSpaceID)}`,
        { method: "POST", body: JSON.stringify({ goal_id: goalID, source_plan_id: null, recovery_mode: null }) },
        true,
        false,
      );
      if (generated.plans.length < 3 || generated.plans.some((plan) => plan.space_id !== goalSpaceID || plan.goal_id !== selectedGoal.id)) throw new Error(copy.genericError);
      if (generated.recommendation_strategy) setRecommendations((current) => ({ ...current, [generated.proposal_group_id]: generated.recommendation_strategy! }));
      setPlans((current) => [...generated.plans, ...current.filter((plan) => plan.proposal_group_id !== generated.proposal_group_id)]);
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function createGoal(event: FormEvent) {
    event.preventDefault();
    const target = amountToMinor(newGoal.target);
    const allocated = newGoal.allocated ? amountToMinor(newGoal.allocated) : 0;
    const nextErrors: GoalErrors = {};
    if (!newGoal.name.trim()) nextErrors.name = text("Name the goal so everyone knows what this money is for.", "Benenne das Ziel, damit klar ist, wofür das Geld gedacht ist.");
    if (target === null || target <= 0) nextErrors.target = text("Enter a target greater than zero, with no more than two decimal places.", "Gib einen Zielbetrag über null mit höchstens zwei Nachkommastellen ein.");
    if (!newGoal.deadline || newGoal.deadline < householdToday) nextErrors.deadline = text("Choose today or a later date.", "Wähle heute oder ein späteres Datum.");
    if (allocated === null || allocated < 0) nextErrors.allocated = text("Enter zero or a positive amount, with no more than two decimal places.", "Gib null oder einen positiven Betrag mit höchstens zwei Nachkommastellen ein.");
    if (Object.keys(nextErrors).length || work) {
      setGoalErrors(nextErrors);
      const firstInvalid: GoalField | undefined = (["name", "target", "deadline", "allocated"] as const).find((field) => nextErrors[field]);
      ({ name: goalNameRef, target: goalTargetRef, deadline: goalDeadlineRef, allocated: goalAllocatedRef }[firstInvalid ?? "name"]).current?.focus();
      return;
    }
    clearMessages();
    setGoalErrors({});
    setWork("generate");
    try {
      const created = await api<FinanceGoal>(
        `/finance/goals?space_id=${encodeURIComponent(createSpaceID)}`,
        { method: "POST", body: JSON.stringify({ name: newGoal.name.trim(), target_minor: target, deadline: newGoal.deadline, currently_allocated_minor: allocated, currency: accounts.find((account) => account.space_id === createSpaceID)?.currency ?? "GBP", priority: "IMPORTANT", allowed_funding_sources: [], emergency_buffer_minor: 0, status: "ACTIVE", notes: null }) },
        true,
        false,
      );
      if (created.space_id !== createSpaceID || !allowedSpaceIDs.has(created.space_id)) throw new Error(copy.genericError);
      setLocalGoals((current) => [created, ...current.filter((goal) => goal.id !== created.id)]);
      setGoalID(created.id);
      setNewGoal({ name: "", target: "", deadline: "", allocated: "" });
      setGoalErrors({});
      setNewGoalOpen(false);
      setNotice(text("Goal added. You can compare plans now.", "Ziel hinzugefügt. Du kannst jetzt Pläne vergleichen."));
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function activate(plan: FinancePlan) {
    if (work) return;
    clearMessages();
    setWork("activate");
    try {
      const updated = await api<FinancePlan>(`/finance/plans/${encodeURIComponent(plan.id)}/activate`, { method: "POST" }, true, false);
      if (updated.id !== plan.id || updated.status !== "ACTIVE" || updated.space_id !== plan.space_id || updated.goal_id !== plan.goal_id || !allowedSpaceIDs.has(updated.space_id)) throw new Error(copy.activateError);
      setPlans((current) => current.map((item) => item.id === updated.id
        ? updated
        : item.space_id === updated.space_id && item.goal_id === updated.goal_id && item.status === "ACTIVE"
          ? { ...item, status: "SUPERSEDED" }
          : item));
      setNotice(copy.planChosen);
    } catch (caught: unknown) {
      if (errorStatus(caught) === 409) {
        try {
          const refreshed = await api<FinancePlanSet>(
            `/finance/plans/generate?space_id=${encodeURIComponent(plan.space_id)}`,
            { method: "POST", body: JSON.stringify({ goal_id: plan.goal_id, source_plan_id: null, recovery_mode: null }) },
            true,
            false,
          );
          if (refreshed.plans.length < 3 || refreshed.plans.some((item) => item.space_id !== plan.space_id || item.goal_id !== plan.goal_id)) throw new Error(copy.activateError);
          if (refreshed.recommendation_strategy) setRecommendations((current) => ({ ...current, [refreshed.proposal_group_id]: refreshed.recommendation_strategy! }));
          setPlans((current) => [
            ...refreshed.plans,
            ...current.filter((item) => item.goal_id !== plan.goal_id || item.status === "ACTIVE"),
          ]);
          setPlanOptionsOpen(true);
          setNotice(text(
            "Another savings plan changed, so these amounts have been updated. Choose the plan you want.",
            "Ein anderer Sparplan hat sich geändert. Deshalb wurden diese Beträge aktualisiert. Wähle den gewünschten Plan.",
          ));
          return;
        } catch {
          setError(copy.activateError);
          return;
        }
      }
      setError(copy.activateError);
    } finally {
      setWork("");
    }
  }

  async function createPayday(event: FormEvent) {
    event.preventDefault();
    if (!activePlan || !sourceAccountID || !destinationAccountID || sourceAccountID === destinationAccountID || work) {
      setError(copy.genericError);
      return;
    }
    clearMessages();
    setWork("payday");
    try {
      const created = await api<FinancePaydayAction>("/finance/payday-actions", { method: "POST", body: JSON.stringify({ plan_id: activePlan.id, source_account_id: sourceAccountID, destination_account_id: destinationAccountID }) }, true, false);
      if (created.space_id !== activePlan.space_id) throw new Error(copy.genericError);
      setActions((current) => [created, ...current]);
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function saveResolution(action: FinancePaydayAction) {
    const form = resolution[action.id] ?? { status: "DONE" as const, changed: "", note: "" };
    const changedAmount = form.status === "CHANGED" ? amountToMinor(form.changed) : null;
    if (form.status === "CHANGED" && changedAmount === null) {
      setError(copy.formError);
      return;
    }
    clearMessages();
    setWork("payday");
    try {
      const updated = await api<FinancePaydayAction>(`/finance/payday-actions/${encodeURIComponent(action.id)}/resolve`, { method: "POST", body: JSON.stringify({ status: form.status, changed_amount_minor: changedAmount, note: form.note.trim() || null }) }, true, false);
      setActions((current) => current.map((item) => item.id === updated.id ? updated : item));
      setNotice(copy.actionSaved);
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function measureHabit(habit: FinanceHabit) {
    if (work) return;
    clearMessages();
    setWork("habit");
    try {
      const updated = await api<FinanceHabit>(`/finance/habits/${encodeURIComponent(habit.id)}/measure`, { method: "POST" }, true, false);
      setHabits((current) => current.map((item) => item.id === updated.id ? updated : item));
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function reviewHabit(habit: FinanceHabit) {
    const form = habitReview[habit.id] ?? { decision: "KEEP" as const, friction: "1", note: "" };
    const friction = Number(form.friction);
    if (!Number.isInteger(friction) || friction < 1 || friction > 5) return;
    clearMessages();
    setWork("habit");
    try {
      const updated = await api<FinanceHabit>(`/finance/habits/${encodeURIComponent(habit.id)}/review`, { method: "POST", body: JSON.stringify({ decision: form.decision, friction_rating: friction, note: form.note.trim() || null }) }, true, false);
      setHabits((current) => current.map((item) => item.id === updated.id ? updated : item));
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  async function evaluatePurchase(event: FormEvent) {
    event.preventDefault();
    const amount = amountToMinor(purchase.amount);
    const account = purchaseAccounts.find((item) => item.id === purchase.accountID) ?? null;
    if (!purchase.name.trim() || amount === null || amount <= 0 || !purchase.desiredDate || purchase.desiredDate < householdToday || !account || (purchase.laterDate && purchase.laterDate <= purchase.desiredDate)) {
      setError(copy.formError);
      return;
    }
    clearMessages();
    setWork("purchase");
    try {
      const created = await api<FinancePurchaseProposal>(
        `/finance/proposals?space_id=${encodeURIComponent(account.space_id)}`,
        { method: "POST", body: JSON.stringify({ reviewed: true, source_kind: "TEXT", source_text: purchase.name.trim(), source_metadata: {}, name: purchase.name.trim(), amount_low_minor: amount, amount_high_minor: amount, desired_date: purchase.desiredDate, recurrence: "ONE_OFF", payment_account_id: account.id, purpose: purchase.purpose.trim() || null, beneficiary: purchase.beneficiary.trim() || null, lines: [], unitemised_remainder_minor: 0, cheaper_alternative_minor: null, later_date: purchase.laterDate || null, uncertainties: [], currency: account.currency }) },
        true,
        false,
      );
      setProposals((current) => [created, ...current.filter((item) => item.id !== created.id)]);
      const endDate = [addDays(householdToday, 365), purchase.desiredDate, purchase.laterDate].filter(Boolean).sort().at(-1)!;
      const forecast = await api<FinanceForecast>(
        `/finance/forecasts?space_id=${encodeURIComponent(account.space_id)}`,
        { method: "POST", body: JSON.stringify({ end_date: endDate, currency: account.currency, household_buffer_minor: Math.max(0, ...[...activePlanLookup.values()].filter((plan) => plan.currency === account.currency).map((plan) => plan.household_buffer_minor)) }) },
        true,
        false,
      );
      const evaluated = await api<FinancePurchaseEvaluation>(`/finance/proposals/${encodeURIComponent(created.id)}/evaluate`, { method: "POST", body: JSON.stringify({ forecast_id: forecast.id }) }, true, false);
      if (evaluated.proposal_id !== created.id) throw new Error(copy.proposalError);
      setProposals((current) => [{ ...created, status: "EVALUATED" }, ...current.filter((item) => item.id !== created.id)]);
      setEvaluation(evaluated);
    } catch {
      setError(copy.proposalError);
    } finally {
      setWork("");
    }
  }

  async function retryEvaluation(proposal: FinancePurchaseProposal) {
    const account = purchaseAccounts.find((item) => item.id === proposal.payment_account_id && item.currency === proposal.currency) ?? null;
    if (!account || work) {
      setError(copy.proposalError);
      return;
    }
    clearMessages();
    setWork("purchase");
    try {
      const endDate = [addDays(householdToday, 365), proposal.desired_date, proposal.later_date]
        .filter((value): value is string => Boolean(value))
        .sort()
        .at(-1)!;
      const forecast = await api<FinanceForecast>(
        `/finance/forecasts?space_id=${encodeURIComponent(account.space_id)}`,
        { method: "POST", body: JSON.stringify({ end_date: endDate, currency: account.currency, household_buffer_minor: Math.max(0, ...[...activePlanLookup.values()].filter((plan) => plan.currency === account.currency).map((plan) => plan.household_buffer_minor)) }) },
        true,
        false,
      );
      const evaluated = await api<FinancePurchaseEvaluation>(`/finance/proposals/${encodeURIComponent(proposal.id)}/evaluate`, { method: "POST", body: JSON.stringify({ forecast_id: forecast.id }) }, true, false);
      if (evaluated.proposal_id !== proposal.id) throw new Error(copy.proposalError);
      setProposals((current) => current.map((item) => item.id === proposal.id ? { ...item, status: "EVALUATED" } : item));
      setEvaluation(evaluated);
    } catch {
      setError(copy.proposalError);
    } finally {
      setWork("");
    }
  }

  async function approveScenario(scenario: FinancePurchaseScenario) {
    if (!evaluation || (!scenario.passed && scenario.scenario !== "DO_NOTHING") || work) return;
    clearMessages();
    setWork("approve");
    try {
      const updated = await api<FinancePurchaseProposal>(`/finance/proposals/${encodeURIComponent(evaluation.proposal_id)}/approve`, { method: "POST", body: JSON.stringify({ evaluation_id: evaluation.id, scenario: scenario.scenario }) }, true, false);
      if (updated.status !== "APPROVED") throw new Error(copy.genericError);
      setProposals((current) => current.map((item) => item.id === updated.id ? updated : item));
      setEvaluation(null);
      setNotice(copy.approved);
      setPurchase((current) => ({ ...current, name: "", amount: "", purpose: "", beneficiary: "", laterDate: "" }));
    } catch {
      setError(copy.genericError);
    } finally {
      setWork("");
    }
  }

  if (state === "loading") return <div className="finance-adult-skeleton" aria-label={copy.loading} aria-busy="true"><div /><div /><div /></div>;
  if (state === "error") return <div className="finance-adult-state is-error" role="alert"><AlertCircle aria-hidden="true" size={24} /><div><strong>{copy.errorTitle}</strong><p>{copy.errorDetail}</p></div><button type="button" className="button button--secondary" onClick={() => setRetryKey((value) => value + 1)}>{copy.retry}</button></div>;

  const selectedActivePlan = activePlan;
  const featuredPlan = selectedActivePlan ?? recommendedPlan ?? planChoices[0] ?? null;
  const requiredPace = (goal: FinanceGoal) => {
    const savedPlan = activePlanLookup.get(goal.id)
      ?? latestPlanGroup(plans.filter((plan) => plan.goal_id === goal.id))[0]
      ?? null;
    return savedPlan
      ? requiredMonthly(savedPlan, goal)
      : Math.ceil(
          Math.max(0, goal.remaining_minor)
            / monthsUntil(goal.deadline, householdToday || goal.created_at.slice(0, 10)),
        );
  };
  const activeGoalPlans = visibleGoals.flatMap((goal) => {
    const plan = activePlanLookup.get(goal.id);
    return plan ? [{ goal, plan }] : [];
  });
  const allocationTotals = [...activeGoalPlans.reduce((totals, { plan }) => {
    totals.set(plan.currency, (totals.get(plan.currency) ?? 0) + plannedMonthly(plan));
    return totals;
  }, new Map<string, number>()).entries()].sort(([left], [right]) => left.localeCompare(right));
  const featuredBasis = featuredPlan
    ? `${featuredPlan.forecast_coverage_end
      ? `${text("Based on spending through", "Auf Basis der Ausgaben bis")} ${formatDate(featuredPlan.forecast_coverage_end, locale)}`
      : copy.answerBases[answerBasis(featuredPlan)]}${typeof featuredPlan.confidence_bps === "number"
      ? ` · ${text("about", "etwa")} ${Math.round(featuredPlan.confidence_bps / 100)}% ${text("sure", "sicher")}`
      : ""}`
    : null;
  const selectedPlanIDs = new Set(plans.filter((plan) => plan.goal_id === selectedGoal?.id).map((plan) => plan.id));
  const selectedActions = actions.filter((action) => selectedPlanIDs.has(action.plan_id));
  const pendingPayday = activePlan
    ? selectedActions.find((action) => action.plan_id === activePlan.id && action.status === "PENDING") ?? null
    : null;
  const activeHabits = habits.filter((habit) => habit.space_id === spaceID && ["ACTIVE", "PAUSED"].includes(habit.status));
  const spaceProposals = proposals.filter((proposal) => proposal.space_id === spaceID);
  const purchaseAssumptions = evaluation
    ? [...new Set(evaluation.scenarios.flatMap((scenario) => scenario.assumptions ?? []))]
    : [];
  const purchaseConfidence = evaluation && typeof evaluation.historical_context.confidence_bps === "number"
    ? Math.round(evaluation.historical_context.confidence_bps / 100)
    : evaluation?.data_through_at ? 80 : 70;
  const purchaseBasis = evaluation
    ? [
        evaluation.data_through_at
          ? `${text("Based on spending through", "Basierend auf Ausgaben bis")} ${formatDate(evaluation.data_through_at.slice(0, 10), locale)}`
          : text("Based on saved balances and bills", "Basierend auf gespeicherten Kontoständen und Rechnungen"),
        purchaseAssumptions[0] ?? null,
        `${text("about", "ungefähr")} ${purchaseConfidence}% ${text("sure", "sicher")}`,
      ].filter((item): item is string => Boolean(item)).join(" · ")
    : null;

  return (
    <div className="finance-adult-page finance-plans-page">
      <header className="finance-adult-heading"><div><span className="finance-status-label"><Target aria-hidden="true" size={15} /> {text("Savings plan", "Sparplan")}</span><h2>{text("Savings plan", "Sparplan")}</h2><p>{text("Keep every goal, deadline and monthly commitment in one place.", "Behalte alle Ziele, Fristen und monatlichen Beträge an einem Ort.")}</p></div></header>
      {error ? <p className="form-error" role="alert">{error}</p> : null}{notice ? <p className="form-success" role="status">{notice}</p> : null}
      <section className="finance-plan-at-glance" aria-labelledby="finance-plan-at-glance-title">
        <header><div><h3 id="finance-plan-at-glance-title">{text("Your savings goals", "Deine Sparziele")}</h3><p>{text("Each chosen amount is a separate monthly allocation. The same money is never shown as funding two goals.", "Jeder gewählte Betrag ist eine eigene monatliche Zuweisung. Dasselbe Geld wird nie für zwei Ziele eingeplant.")}</p></div></header>
        <article className="finance-plan-allocation-summary" aria-labelledby="finance-plan-allocation-title">
          <div><span>{text("Combined monthly commitment", "Monatliche Gesamtsumme")}</span><h4 id="finance-plan-allocation-title">{text("Your separate allocations", "Deine getrennten Zuweisungen")}</h4></div>
          {allocationTotals.length ? <dl>{allocationTotals.map(([currency, amount]) => <div key={currency}><dt>{currency}</dt><dd>{formatCurrency(amount, currency, locale)} {text("a month", "pro Monat")}</dd></div>)}</dl> : <p>{text("No monthly plan is chosen yet. Open a goal to compare Easy, Medium and Hard.", "Noch ist kein monatlicher Plan gewählt. Öffne ein Ziel, um Einfach, Mittel und Anspruchsvoll zu vergleichen.")}</p>}
        </article>
        {visibleGoals.length ? <div className="finance-goal-overview-grid" role="list">{visibleGoals.map((goal) => { const goalPlan = activePlanLookup.get(goal.id) ?? null; const shortfall = goalPlan ? targetShortfall(goalPlan) : null; const goalSpace = spaces.find((space) => space.id === goal.space_id); return <article key={goal.id} role="listitem" className={cn("finance-goal-overview-card", goal.id === goalID && "is-selected")} aria-labelledby={`finance-goal-overview-${goal.id}`}><header><div><span>{goalSpace?.name ?? text("Savings goal", "Sparziel")}</span><h4 id={`finance-goal-overview-${goal.id}`}>{goal.name}</h4></div><button type="button" className="button button--secondary" aria-pressed={goal.id === goalID} onClick={() => { setGoalID(goal.id); setPlanOptionsOpen(true); }}>{text("Review plan", "Plan prüfen")}</button></header><p><strong>{formatCurrency(goal.currently_allocated_minor, goal.currency, locale)}</strong> {text("of", "von")} {formatCurrency(goal.target_minor, goal.currency, locale)} {text("saved", "gespart")}</p><progress aria-label={text(`${goal.name} progress`, `Fortschritt für ${goal.name}`)} max={Math.max(1, goal.target_minor)} value={Math.min(goal.currently_allocated_minor, goal.target_minor)} /><dl><div><dt>{text("Deadline", "Frist")}</dt><dd>{formatDate(goal.deadline, locale)}</dd></div><div><dt>{copy.requiredMonthly}</dt><dd>{formatCurrency(requiredPace(goal), goal.currency, locale)}</dd></div><div><dt>{text("Chosen plan", "Gewählter Plan")}</dt><dd>{goalPlan ? `${copy.tiers[effortLevel(goalPlan)]} · ${formatCurrency(plannedMonthly(goalPlan), goalPlan.currency, locale)} ${text("a month", "pro Monat")}` : text("Not chosen yet", "Noch nicht gewählt")}</dd></div>{goalPlan ? <><div><dt>{copy.supportedDate}</dt><dd>{formatDate(projectedFinish(goalPlan, goal), locale)}</dd></div><div><dt>{copy.targetPosition}</dt><dd>{shortfall && shortfall > 0 ? `${copy.shortfall} ${formatCurrency(shortfall, goalPlan.currency, locale)}` : copy.onTarget}</dd></div></> : null}</dl></article>; })}</div> : <div className="finance-adult-empty"><p>{copy.noGoals}</p><button type="button" className="button button--primary" onClick={() => { setPlanOptionsOpen(true); setNewGoalOpen(true); }}>{text("Set a savings goal", "Sparziel festlegen")}</button></div>}
        {pendingPayday ? <aside className="finance-plan-next-action"><CalendarCheck2 aria-hidden="true" size={20} /><div><strong>{text("Next action", "Nächster Schritt")}: {copy.move} {formatCurrency(pendingPayday.amount_minor, pendingPayday.currency, locale)}</strong><p>{formatDate(pendingPayday.due_date, locale)} · {copy.safeAfter} {formatCurrency(pendingPayday.safe_after_transfer_minor, pendingPayday.currency, locale)}</p></div></aside> : null}
      </section>

      <section className="finance-plan-monthly-breakdown" aria-labelledby="finance-plan-monthly-title">
        <header><div><h3 id="finance-plan-monthly-title">{text("This month", "Dieser Monat")}</h3><p>{text("Income, spending and what is left to support your goals.", "Einnahmen, Ausgaben und was für deine Ziele übrig bleibt.")}</p></div></header>
        {monthlySummary?.currencies.length ? <div className="finance-plan-monthly-grid">{monthlySummary.currencies.map((summary) => <article key={summary.currency}><h4>{summary.currency}</h4><dl><div><dt>{text("Income", "Einnahmen")}</dt><dd>{formatCurrency(summary.income_minor, summary.currency, locale)}</dd></div><div><dt>{text("Spending", "Ausgaben")}</dt><dd>{formatCurrency(summary.spending_minor, summary.currency, locale)}</dd></div><div><dt>{summary.saved_minor >= 0 ? text("Saved or left over", "Gespart oder übrig") : text("Beyond income", "Über den Einnahmen")}</dt><dd>{formatCurrency(Math.abs(summary.saved_minor), summary.currency, locale)}</dd></div></dl></article>)}</div> : <p className="finance-adult-empty">{text("No income or spending is recorded for this calendar month yet.", "Für diesen Kalendermonat sind noch keine Einnahmen oder Ausgaben erfasst.")}</p>}
      </section>
      {featuredBasis ? <p className="finance-plan-basis finance-savings-basis-note"><small>{featuredBasis}.</small></p> : monthlySummary?.data_through ? <p className="finance-plan-basis finance-savings-basis-note"><small>{text("This month uses records through", "Dieser Monat nutzt Einträge bis")} {formatDate(monthlySummary.data_through, locale)}.</small></p> : null}
      {pendingPlan ? <section className="finance-plan-confirm" aria-labelledby="finance-plan-confirm-title"><div><strong id="finance-plan-confirm-title">{text("Use this as your long-term saving plan?", "Diesen langfristigen Sparplan nutzen?")}</strong><p>{copy.tiers[effortLevel(pendingPlan)]} · {planMoney(pendingPlan, plannedMonthly(pendingPlan))} {text("a month. Before each payday action, HausKlar separately checks current bills and your protected cash buffer.", "pro Monat. Vor jeder Zahltag-Aktion prüft HausKlar aktuelle Rechnungen und den geschützten Geldpuffer separat.")}</p></div><div><button type="button" className="button button--secondary" onClick={() => setPendingPlan(null)}>{text("Keep comparing", "Weiter vergleichen")}</button><button type="button" className="button button--primary" disabled={Boolean(work)} aria-busy={work === "activate"} onClick={() => void activate(pendingPlan).then(() => setPendingPlan(null))}>{work === "activate" ? copy.activating : text("Yes, use this plan", "Ja, diesen Plan nutzen")}</button></div></section> : null}

      <details className="finance-plan-options" open={planOptionsOpen} onToggle={(event) => setPlanOptionsOpen(event.currentTarget.open)}>
        <summary>{text("Savings goal and three plans", "Sparziel und drei Pläne")}</summary>
      <section className="finance-plan-choices" aria-labelledby="finance-plan-choice-title">
        <header><div><h3 id="finance-plan-choice-title">{copy.title}</h3><p>{visibleGoals.length ? copy.detail : copy.noGoals}</p></div><div className="finance-plan-generate">{visibleGoals.length ? <div className="field"><label htmlFor="finance-plan-goal">{copy.goal}</label><select id="finance-plan-goal" value={goalID} onChange={(event) => setGoalID(event.target.value)}>{visibleGoals.map((goal) => <option value={goal.id} key={goal.id}>{goal.name} · {spaces.find((space) => space.id === goal.space_id)?.name}</option>)}</select></div> : null}<button type="button" className="button button--secondary" onClick={() => { setGoalErrors({}); if (!newGoalOpen) setCreateSpaceID(selectedGoal?.space_id ?? spaces[0]?.id ?? ""); setNewGoalOpen((open) => !open); }}>{newGoalOpen ? text("Cancel", "Abbrechen") : text("New savings goal", "Neues Sparziel")}</button>{visibleGoals.length ? <button type="button" className="button button--primary" disabled={Boolean(work) || !goalID} aria-busy={work === "generate"} onClick={() => void generatePlans()}>{work === "generate" ? copy.generating : copy.generate}</button> : null}</div></header>
        {newGoalOpen ? <form className="finance-plan-new-goal" onSubmit={(event) => void createGoal(event)} noValidate aria-busy={work === "generate"}>{spaces.length > 1 ? <div className="field"><label htmlFor="finance-new-goal-space">{text("Who is this plan for?", "Für wen ist dieser Plan?")}</label><select id="finance-new-goal-space" value={createSpaceID} onChange={(event) => setCreateSpaceID(event.target.value)}>{spaces.map((space) => <option value={space.id} key={space.id}>{space.name}</option>)}</select></div> : null}<div className="field"><label htmlFor="finance-new-goal-name">{text("What are you saving for?", "Wofür sparst du?")}</label><input ref={goalNameRef} id="finance-new-goal-name" type="text" autoComplete="off" value={newGoal.name} aria-invalid={goalErrors.name ? "true" : undefined} aria-describedby={goalErrors.name ? "finance-new-goal-name-error" : undefined} onChange={(event) => setNewGoal((current) => ({ ...current, name: event.target.value }))} />{goalErrors.name ? <p id="finance-new-goal-name-error" className="field-error finance-goal-field-error">{goalErrors.name}</p> : null}</div><div className="field"><label htmlFor="finance-new-goal-target">{text("Target amount", "Zielbetrag")}</label><input ref={goalTargetRef} id="finance-new-goal-target" type="text" inputMode="decimal" autoComplete="off" spellCheck={false} value={newGoal.target} aria-invalid={goalErrors.target ? "true" : undefined} aria-describedby={goalErrors.target ? "finance-new-goal-target-error" : undefined} onChange={(event) => setNewGoal((current) => ({ ...current, target: event.target.value }))} />{goalErrors.target ? <p id="finance-new-goal-target-error" className="field-error finance-goal-field-error">{goalErrors.target}</p> : null}</div><div className="field"><label htmlFor="finance-new-goal-date">{text("Target date", "Zieldatum")}</label><input ref={goalDeadlineRef} id="finance-new-goal-date" type="date" min={householdToday} autoComplete="off" value={newGoal.deadline} aria-invalid={goalErrors.deadline ? "true" : undefined} aria-describedby={goalErrors.deadline ? "finance-new-goal-date-error" : undefined} onChange={(event) => setNewGoal((current) => ({ ...current, deadline: event.target.value }))} />{goalErrors.deadline ? <p id="finance-new-goal-date-error" className="field-error finance-goal-field-error">{goalErrors.deadline}</p> : null}</div><div className="field"><label htmlFor="finance-new-goal-allocated">{text("Already set aside (optional)", "Schon zurückgelegt (optional)")}</label><input ref={goalAllocatedRef} id="finance-new-goal-allocated" type="text" inputMode="decimal" autoComplete="off" spellCheck={false} value={newGoal.allocated} aria-invalid={goalErrors.allocated ? "true" : undefined} aria-describedby={goalErrors.allocated ? "finance-new-goal-allocated-error" : undefined} onChange={(event) => setNewGoal((current) => ({ ...current, allocated: event.target.value }))} />{goalErrors.allocated ? <p id="finance-new-goal-allocated-error" className="field-error finance-goal-field-error">{goalErrors.allocated}</p> : null}</div><button type="submit" className="button button--primary" disabled={Boolean(work)} aria-busy={work === "generate"}>{text("Save goal", "Ziel speichern")}</button></form> : null}
        {selectedGoal ? <div className="finance-plan-progress" aria-label={text("Goal progress", "Zielfortschritt")}><div><span>{selectedGoal.name}</span><strong>{formatCurrency(selectedGoal.currently_allocated_minor, selectedGoal.currency, locale)} {text("saved", "gespart")}</strong></div><progress max={selectedGoal.target_minor} value={Math.min(selectedGoal.currently_allocated_minor, selectedGoal.target_minor)} /><span>{formatCurrency(selectedGoal.remaining_minor, selectedGoal.currency, locale)} {text("left by", "fehlen bis")} {formatDate(selectedGoal.deadline, locale)}</span></div> : null}
        {recommendedPlan ? <aside className="finance-plan-reason"><strong>{text("Why Medium is recommended", "Warum Mittel empfohlen wird")}</strong><p>{recommendedPlan.rationale}</p></aside> : null}
        {planChoices.length ? (
          <div className="finance-plan-choice-grid finance-tier-choice-grid" role="list">
            {planChoices.map((plan) => {
              const tier = effortLevel(plan);
              const shortfall = targetShortfall(plan);
              const changes = plan.categories.filter((category) => category.reduction_minor > 0);
              const visibleChanges = changes.slice(0, 2);
              const furtherChanges = changes.slice(2);
              return (
                <article key={plan.id} role="listitem" aria-labelledby={`finance-plan-tier-${plan.id}`} className={cn("finance-tier-card", `is-${tier.toLowerCase()}`, plan.status === "ACTIVE" && "is-active", tier === "MEDIUM" && "is-recommended")}>
                  <header><div><h4 id={`finance-plan-tier-${plan.id}`}>{copy.tiers[tier]}</h4><p>{copy.tierDetails[tier]}</p></div><div className="finance-tier-badges">{tier === "MEDIUM" ? <span>{copy.recommended}</span> : null}{plan.status === "ACTIVE" ? <span>{copy.active}</span> : null}</div></header>
                  <p className="finance-tier-monthly"><strong>{planMoney(plan, plannedMonthly(plan))}</strong> {text("a month", "pro Monat")}</p>
                  <p className="finance-plan-card-reason">{plan.rationale}</p>
                  <dl className="finance-tier-metrics"><div><dt>{copy.requiredMonthly}</dt><dd>{planMoney(plan, requiredMonthly(plan, selectedGoal))}</dd></div><div><dt>{copy.expectedAtTarget}</dt><dd>{planMoney(plan, expectedAtTarget(plan, selectedGoal))}</dd></div><div><dt>{copy.targetPosition}</dt><dd>{shortfall > 0 ? `${copy.shortfall} ${planMoney(plan, shortfall)}` : copy.onTarget}</dd></div><div><dt>{copy.supportedDate}</dt><dd>{formatDate(projectedFinish(plan, selectedGoal), locale)}</dd></div><div><dt>{copy.buffer}</dt><dd>{planMoney(plan, plan.household_buffer_minor)}</dd></div></dl>
                  <section className="finance-tier-changes" aria-label={copy.reductions}><h5>{copy.reductions}</h5>{visibleChanges.length ? <ul>{visibleChanges.map((category) => <li key={category.category_id}><span>{category.name}</span><strong>{planMoney(plan, category.reduction_minor)} {text("less each month", "weniger pro Monat")}</strong></li>)}</ul> : <p>{copy.noReductions}</p>}{furtherChanges.length ? <details><summary>{text(`${furtherChanges.length} more changes`, `${furtherChanges.length} weitere Änderungen`)}</summary><ul>{furtherChanges.map((category) => <li key={category.category_id}><span>{category.name}</span><strong>{planMoney(plan, category.reduction_minor)} {text("less each month", "weniger pro Monat")}</strong></li>)}</ul></details> : null}<p>{copy.protectedCount}: <strong>{plan.protected_category_count}</strong></p></section>
                  {plan.assumptions?.length ? <details className="finance-tier-assumptions"><summary>{copy.tierAssumptions}</summary><ul>{plan.assumptions.map((assumption) => <li key={assumption}>{assumption}</li>)}</ul></details> : null}
                  {plan.status !== "ACTIVE" ? <button type="button" className="button button--primary" disabled={Boolean(work)} onClick={() => setPendingPlan(plan)}>{copy.activate}</button> : null}
                </article>
              );
            })}
          </div>
        ) : <p className="finance-adult-empty">{copy.noPlans}</p>}
      </section>
      </details>

      {showDeepTools ? <>
      <details className="finance-plan-admin">
        <summary>{text("Payday actions and habit details", "Zahltag-Aktionen und Gewohnheiten")}{pendingPayday || activeHabits.length ? ` · ${Number(Boolean(pendingPayday)) + activeHabits.length}` : ""}</summary>
      <section className="finance-payday-section" aria-labelledby="finance-payday-title"><header><div><h3 id="finance-payday-title"><PiggyBank aria-hidden="true" size={19} /> {copy.paydayTitle}</h3><p>{copy.paydayDetail}</p></div></header>{activePlan && paydaySources.length && paydayDestinations.length ? <form onSubmit={(event) => void createPayday(event)}><div className="field"><label htmlFor="finance-payday-source">{copy.sourceAccount}</label><select id="finance-payday-source" value={sourceAccountID} onChange={(event) => setSourceAccountID(event.target.value)}>{paydaySources.map((account) => <option value={account.id} key={account.id}>{account.label}</option>)}</select></div><div className="field"><label htmlFor="finance-payday-destination">{copy.destinationAccount}</label><select id="finance-payday-destination" value={destinationAccountID} onChange={(event) => setDestinationAccountID(event.target.value)}>{paydayDestinations.map((account) => <option value={account.id} key={account.id}>{account.label}</option>)}</select></div><button type="submit" className="button button--secondary" disabled={Boolean(work) || sourceAccountID === destinationAccountID}>{work === "payday" ? copy.creatingPayday : copy.createPayday}</button></form> : null}{selectedActions.length ? <div className="finance-payday-list">{selectedActions.map((action) => { const form = resolution[action.id] ?? { status: "DONE" as const, changed: "", note: "" }; const basis = action.answer_mode === "DATED_EXACT" ? `${locale === "de" ? "Exakter gespeicherter Stand" : "Exact saved balance"}${action.data_through_at ? ` · ${formatDateTime(action.data_through_at, locale)}` : ""}` : action.answer_mode === "CURRENT_EXACT" ? (locale === "de" ? "Exakter aktueller Stand" : "Exact current balance") : null; return <article key={action.id}><header><CalendarCheck2 aria-hidden="true" size={20} /><div><strong>{copy.move} {formatCurrency(action.amount_minor, action.currency, locale)}</strong><span>{formatDate(action.due_date, locale)} · {spaceAccounts.find((account) => account.id === action.source_account_id)?.label} → {spaceAccounts.find((account) => account.id === action.destination_account_id)?.label}</span></div><span>{copy.paydayStatuses[action.status]}</span></header><p>{copy.safeAfter}: <strong>{formatCurrency(action.safe_after_transfer_minor, action.currency, locale)}</strong></p>{basis ? <small>{basis}</small> : null}{action.status === "PENDING" ? <div className="finance-payday-resolution"><div className="field"><label htmlFor={`finance-payday-resolution-${action.id}`}>{copy.resolution}</label><select id={`finance-payday-resolution-${action.id}`} value={form.status} onChange={(event) => setResolution((current) => ({ ...current, [action.id]: { ...form, status: event.target.value as typeof form.status } }))}><option value="DONE">{copy.done}</option><option value="SKIPPED">{copy.skipped}</option><option value="CHANGED">{copy.changed}</option></select></div>{form.status === "CHANGED" ? <div className="field"><label htmlFor={`finance-payday-changed-${action.id}`}>{copy.changedAmount}</label><input id={`finance-payday-changed-${action.id}`} type="text" inputMode="decimal" autoComplete="off" value={form.changed} onChange={(event) => setResolution((current) => ({ ...current, [action.id]: { ...form, changed: event.target.value } }))} /></div> : null}<div className="field"><label htmlFor={`finance-payday-note-${action.id}`}>{copy.note}</label><input id={`finance-payday-note-${action.id}`} autoComplete="off" value={form.note} onChange={(event) => setResolution((current) => ({ ...current, [action.id]: { ...form, note: event.target.value } }))} /></div><button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void saveResolution(action)}>{copy.saveResolution}</button></div> : null}</article>; })}</div> : <p>{copy.noPayday}</p>}</section>

      <section className="finance-habit-progress" aria-labelledby="finance-habit-progress-title"><header><h3 id="finance-habit-progress-title"><Repeat2 aria-hidden="true" size={19} /> {copy.habitsTitle}</h3></header>{activeHabits.length ? activeHabits.map((habit) => { const form = habitReview[habit.id] ?? { decision: "KEEP" as const, friction: "1", note: "" }; return <article key={habit.id}><header><div><strong>{habit.name}</strong><p>{habit.trigger}</p></div><span>{copy.habitSlots[habit.slot]}</span></header><dl><div><dt>{copy.baseline}</dt><dd>{formatCurrency(habit.baseline_minor, habit.currency, locale)}</dd></div><div><dt>{copy.actual}</dt><dd>{formatCurrency(habit.actual_spend_minor, habit.currency, locale)}</dd></div><div><dt>{copy.realised}</dt><dd>{formatCurrency(habit.realised_saving_minor, habit.currency, locale)}</dd></div><div><dt>{copy.displacement}</dt><dd>{formatCurrency(habit.displacement_minor, habit.currency, locale)}</dd></div></dl><button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void measureHabit(habit)}><Gauge aria-hidden="true" size={16} /> {work === "habit" ? copy.measuring : copy.measure}</button><details><summary>{copy.reviewHabit}</summary><div className="finance-habit-review-form"><div className="field"><label htmlFor={`finance-habit-decision-${habit.id}`}>{copy.decision}</label><select id={`finance-habit-decision-${habit.id}`} value={form.decision} onChange={(event) => setHabitReview((current) => ({ ...current, [habit.id]: { ...form, decision: event.target.value as typeof form.decision } }))}><option value="KEEP">{copy.keep}</option><option value="ADJUST">{copy.adjust}</option><option value="STOP">{copy.stop}</option></select></div><div className="field"><label htmlFor={`finance-habit-friction-${habit.id}`}>{copy.friction}</label><select id={`finance-habit-friction-${habit.id}`} value={form.friction} onChange={(event) => setHabitReview((current) => ({ ...current, [habit.id]: { ...form, friction: event.target.value as typeof form.friction } }))}>{[1,2,3,4,5].map((value) => <option value={value} key={value}>{value === 1 ? copy.easy : value === 5 ? copy.hard : value}</option>)}</select></div><div className="field"><label htmlFor={`finance-habit-note-${habit.id}`}>{copy.note}</label><input id={`finance-habit-note-${habit.id}`} autoComplete="off" value={form.note} onChange={(event) => setHabitReview((current) => ({ ...current, [habit.id]: { ...form, note: event.target.value } }))} /></div><button type="button" className="button button--primary" disabled={Boolean(work)} onClick={() => void reviewHabit(habit)}>{copy.saveReview}</button></div></details></article>; }) : null}</section>
      </details>

      <section className="finance-proposal-section" aria-labelledby="finance-proposal-title">
        <header>
          <div>
            <h3 id="finance-proposal-title"><ShoppingBag aria-hidden="true" size={19} /> {copy.purchaseTitle}</h3>
            <p>{text("Tell Finance what, roughly how much, and when. It will use any saved price evidence and say when no alternative is known.", "Sag Finance, was du kaufen möchtest, ungefähr wie viel es kostet und wann. Gespeicherte Preisbelege werden genutzt; fehlt eine Alternative, wird das klar gesagt.")}</p>
          </div>
        </header>
        <form onSubmit={evaluatePurchase} aria-busy={work === "purchase"}>
          <div className="finance-proposal-form-grid is-compact">
            <div className="field">
              <label htmlFor="finance-proposal-name">{copy.purchaseName}</label>
              <input id="finance-proposal-name" type="text" autoComplete="off" value={purchase.name} onChange={(event) => setPurchase((current) => ({ ...current, name: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="finance-proposal-amount">{copy.amount}{purchaseCurrency ? ` (${purchaseCurrency})` : ""}</label>
              <input id="finance-proposal-amount" type="text" inputMode="decimal" autoComplete="off" spellCheck={false} placeholder={locale === "de" ? "z. B. 250,00" : "e.g. 250.00"} value={purchase.amount} onChange={(event) => setPurchase((current) => ({ ...current, amount: event.target.value }))} />
            </div>
            <div className="field">
              <label htmlFor="finance-proposal-date">{copy.desiredDate}</label>
              <input id="finance-proposal-date" type="date" min={householdToday} autoComplete="off" value={purchase.desiredDate} onChange={(event) => setPurchase((current) => ({ ...current, desiredDate: event.target.value }))} />
            </div>
          </div>
          <details className="finance-proposal-optional">
            <summary>{text("Optional purchase details", "Optionale Einkaufsdetails")}</summary>
            <div className="finance-proposal-form-grid">
              <div className="field">
                <label htmlFor="finance-proposal-account">{copy.account}</label>
                <select id="finance-proposal-account" value={purchase.accountID} onChange={(event) => setPurchase((current) => ({ ...current, accountID: event.target.value }))}>{purchaseAccounts.map((account) => <option value={account.id} key={account.id}>{account.label}</option>)}</select>
              </div>
              <div className="field"><label htmlFor="finance-proposal-purpose">{copy.purpose}</label><input id="finance-proposal-purpose" type="text" autoComplete="off" value={purchase.purpose} onChange={(event) => setPurchase((current) => ({ ...current, purpose: event.target.value }))} /></div>
              <div className="field"><label htmlFor="finance-proposal-beneficiary">{copy.beneficiary}</label><input id="finance-proposal-beneficiary" type="text" autoComplete="off" value={purchase.beneficiary} onChange={(event) => setPurchase((current) => ({ ...current, beneficiary: event.target.value }))} /></div>
              <div className="field"><label htmlFor="finance-proposal-later">{copy.laterDate}</label><input id="finance-proposal-later" type="date" min={purchase.desiredDate || householdToday} autoComplete="off" value={purchase.laterDate} onChange={(event) => setPurchase((current) => ({ ...current, laterDate: event.target.value }))} /></div>
            </div>
          </details>
          {!purchaseAccounts.length ? <p className="field-error">{text("Add an everyday account before checking a purchase.", "Füge ein Alltagskonto hinzu, bevor du einen Einkauf prüfst.")}</p> : null}
          <button type="submit" className="button button--primary" disabled={Boolean(work) || !purchaseAccounts.length} aria-busy={work === "purchase"}>{work === "purchase" ? copy.evaluating : copy.evaluate}</button>
        </form>
        {evaluation ? (
          <article className={`finance-proposal-evaluation is-${evaluation.verdict.toLowerCase()}`} aria-live="polite">
            <header><div><span>{copy.verdicts[evaluation.verdict]}</span><strong>{evaluatedProposal?.name}</strong></div></header>
            <p className="finance-proposal-rationale">{evaluation.rationale}</p>
            <div className="finance-proposal-scenarios">{evaluation.scenarios.map((scenario) => <article key={scenario.scenario} className={cn(scenario.passed && "is-feasible")}><strong>{copy.scenarios[scenario.scenario]}</strong><span>{copy.scenarioStatuses[scenario.status as keyof typeof copy.scenarioStatuses] ?? scenario.status}</span>{scenario.minimum_household_free_minor !== undefined ? <p>{copy.remainingAfter}: {evaluatedProposal ? formatCurrency(scenario.minimum_household_free_minor, evaluatedProposal.currency, locale) : "—"}</p> : null}{scenario.passed || scenario.scenario === "DO_NOTHING" ? <button type="button" className="button button--primary" disabled={Boolean(work)} onClick={() => void approveScenario(scenario)}>{copy.approve}</button> : null}</article>)}</div>
            {evaluation.evidence_refs.length ? <div className="finance-evidence-links"><strong>{copy.evidence}</strong>{evaluation.evidence_refs.map((reference, index) => { const [kind, id] = reference.split(":", 2); const href = kind === "transaction" && id ? `/?view=finance&section=activity&transaction=${encodeURIComponent(id)}` : kind === "purchase-line" && id ? `/?view=finance&section=more&line=${encodeURIComponent(id)}` : null; const label = kind === "transaction" ? text(`Bank entry ${index + 1}`, `Bankeintrag ${index + 1}`) : kind === "purchase-line" ? text(`Receipt item ${index + 1}`, `Belegartikel ${index + 1}`) : text(`Saved record ${index + 1}`, `Gespeicherter Eintrag ${index + 1}`); return href ? <a href={href} key={reference}><span>{label}</span><span>{copy.openEvidence}</span></a> : <span key={reference}>{label}</span>; })}</div> : null}
            {purchaseBasis ? <p className="finance-plan-basis finance-purchase-basis-note">{purchaseBasis}</p> : null}
          </article>
        ) : spaceProposals.length ? <details className="finance-proposal-history"><summary>{text(`${spaceProposals.length} saved purchase ${spaceProposals.length === 1 ? "check" : "checks"}`, `${spaceProposals.length} gespeicherte Einkaufsprüfung${spaceProposals.length === 1 ? "" : "en"}`)}</summary><ul className="finance-proposal-list">{spaceProposals.map((proposal) => <li key={proposal.id}><span>{proposal.name}</span><strong>{formatCurrency(proposal.amount_high_minor, proposal.currency, locale)}</strong><span>{copy.proposalStatuses[proposal.status]}</span>{proposal.status === "CONFIRMED" ? <button type="button" className="button button--secondary" disabled={Boolean(work)} onClick={() => void retryEvaluation(proposal)}>{copy.retryEvaluation}</button> : null}</li>)}</ul></details> : null}
      </section>
      </> : null}
    </div>
  );
}
