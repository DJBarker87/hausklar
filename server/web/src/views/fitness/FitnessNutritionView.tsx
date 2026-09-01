import {
  BookOpen,
  ChefHat,
  Gauge,
  Link2,
  MoreHorizontal,
  SlidersHorizontal,
  Sparkles,
  Utensils,
} from "lucide-react";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";

import type { FitnessViewProps } from "./FitnessModuleView";
import {
  currentFitnessOnboardingStatus,
  openFitnessOnboarding,
  subscribeFitnessOnboardingStatus,
} from "./FitnessOnboardingView";
import {
  FitnessHouseholdMealsPanel,
  FitnessLogView,
  type FitnessLogMode,
} from "./FitnessLogView";
import {
  FitnessFoodCataloguePanel,
  FitnessMealTemplatesPanel,
  FitnessNutritionTargetsPanel,
  FitnessRecipesPanel,
} from "./FitnessNutritionPanels";
import { FitnessCard, FitnessPageHeading } from "./shared";

type NutritionSection = "log" | "catalogue" | "recipes" | "templates" | "targets" | "household" | "connections";

const manageSections = [
  { id: "catalogue", label: "Foods, barcode & labels", icon: BookOpen },
  { id: "recipes", label: "Recipes", icon: ChefHat },
  { id: "templates", label: "Meal templates", icon: Utensils },
  { id: "targets", label: "Targets & day", icon: SlidersHorizontal },
  { id: "household", label: "Family meal links", icon: Link2 },
  { id: "connections", label: "Connections", icon: Gauge },
] satisfies Array<{ id: Exclude<NutritionSection, "log">; label: string; icon: typeof BookOpen }>;

export function FitnessNutritionView(props: FitnessViewProps) {
  const [section, setSection] = useState<NutritionSection>("log");
  const [logMode, setLogMode] = useState<FitnessLogMode>("food");
  const [newFoodRequest, setNewFoodRequest] = useState(0);
  const manageRef = useRef<HTMLDetailsElement>(null);
  const onboardingStatus = useSyncExternalStore(
    subscribeFitnessOnboardingStatus,
    currentFitnessOnboardingStatus,
    () => null,
  );

  useEffect(() => {
    const query = new URLSearchParams(window.location.search);
    if (query.get("fitness-meal-template")) setSection("templates");
    else if (query.get("fitness-nutrition-target")) setSection("targets");
    const requestedMode = query.get("fitness-log");
    if (["food", "measurement", "sleep", "issue"].includes(requestedMode ?? "")) {
      setLogMode(requestedMode as FitnessLogMode);
      setSection("log");
    }
  }, []);

  function openNewFood() {
    setSection("catalogue");
    setNewFoodRequest((value) => value + 1);
  }

  function openManage(next: Exclude<NutritionSection, "log">) {
    setSection(next);
    if (manageRef.current) manageRef.current.open = false;
  }

  return (
    <section aria-labelledby="fitness-nutrition-title">
      <FitnessPageHeading
        title={section === "log" ? "Log" : manageSections.find((item) => item.id === section)?.label ?? "Log"}
        detail={section === "log" ? "Food first, with the other everyday logs one tap away." : "Daily logging stays separate from setup and maintenance."}
        actions={section !== "log" ? <button type="button" className="button button--secondary" onClick={() => setSection("log")}>Back to Log</button> : undefined}
      />

      <details className="fitness-module__section-tools fitness-log__manage" ref={manageRef}>
        <summary className={section !== "log" ? "is-active" : undefined}><MoreHorizontal aria-hidden="true" size={16} /> Manage</summary>
        <div className="fitness-module__section-tools-menu" role="group" aria-label="Manage food and connections">
          {manageSections.map((item) => { const Icon = item.icon; return <button type="button" key={item.id} className={section === item.id ? "is-active" : undefined} onClick={() => openManage(item.id)}><Icon aria-hidden="true" size={16} /> {item.label}</button>; })}
          {onboardingStatus === "skipped" ? <button type="button" onClick={() => { if (manageRef.current) manageRef.current.open = false; openFitnessOnboarding(); }}><Sparkles aria-hidden="true" size={16} /> Finish Fitness setup</button> : null}
        </div>
      </details>

      {section === "log" ? <FitnessLogView {...props} mode={logMode} onModeChange={setLogMode} onCreateFood={openNewFood} /> : null}
      {section === "catalogue" ? <FitnessFoodCataloguePanel {...props} openCreateRequest={newFoodRequest} /> : null}
      {section === "recipes" ? <FitnessRecipesPanel {...props} /> : null}
      {section === "templates" ? <FitnessMealTemplatesPanel {...props} /> : null}
      {section === "targets" ? <FitnessNutritionTargetsPanel {...props} /> : null}
      {section === "household" ? <FitnessHouseholdMealsPanel {...props} /> : null}
      {section === "connections" ? <FitnessCard title="Connections" detail="Open the section that owns each connection."><div className="fitness-log__connection-actions"><button type="button" className="button button--secondary" onClick={() => props.onSectionChange("training")}>Training watches and calendars</button><button type="button" className="button button--secondary" onClick={() => props.onSectionChange("progress")}>Scales and body measurements</button></div></FitnessCard> : null}
    </section>
  );
}
