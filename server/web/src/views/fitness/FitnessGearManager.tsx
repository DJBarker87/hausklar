import { Footprints, Plus, Star, Trash2 } from "lucide-react";
import { useState } from "react";

import { api } from "../../api";
import type { FitnessGearItem } from "../../fitness/contract";
import { FitnessCard, errorMessage, localDateValue } from "./shared";

export function FitnessGearManager({ items, onChanged, onClose }: { items: FitnessGearItem[]; onChanged: () => void; onClose: () => void }) {
  const [name, setName] = useState("");
  const [brand, setBrand] = useState("");
  const [model, setModel] = useState("");
  const [gearType, setGearType] = useState("running_shoe");
  const [startedAt, setStartedAt] = useState(localDateValue());
  const [defaultSport, setDefaultSport] = useState("running");
  const [busyId, setBusyId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function create() {
    setBusyId("new");
    setError(null);
    try {
      const created = await api<FitnessGearItem>("/fitness/gear", { method: "POST", body: JSON.stringify({ gear_type_key: gearType, name: name.trim(), brand: brand.trim() || null, model: model.trim() || null, variant: null, started_at: startedAt || null, retired_at: null, initial_usage_distance_m: 0, default_for_sport_key: defaultSport || null, notes: null, active: true }) }, true, false);
      if (defaultSport) await api(`/fitness/gear/${encodeURIComponent(created.id)}/default`, { method: "POST", body: JSON.stringify({ sport_key: defaultSport }) }, true, false);
      setName("");
      setBrand("");
      setModel("");
      onChanged();
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function setDefault(item: FitnessGearItem, sportKey: string) {
    setBusyId(item.id);
    setError(null);
    try {
      await api(`/fitness/gear/${encodeURIComponent(item.id)}/default`, { method: "POST", body: JSON.stringify({ sport_key: sportKey }) }, true, false);
      onChanged();
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  async function remove(item: FitnessGearItem) {
    setBusyId(item.id);
    setError(null);
    try {
      await api(`/fitness/gear/${encodeURIComponent(item.id)}`, { method: "DELETE" }, true, false);
      onChanged();
    } catch (requestError) {
      setError(errorMessage(requestError));
    } finally {
      setBusyId(null);
    }
  }

  return <FitnessCard title="Gear and running shoes" detail="Actual gear stays attached to each activity; no automatic replacement distance is imposed.">
    <form className="fitness-module__form" onSubmit={(event) => { event.preventDefault(); void create(); }}>
      <div className="fitness-module__fields">
        <label className="fitness-module__field">Name<input autoFocus required value={name} onChange={(event) => setName(event.target.value)} placeholder="Daily trainers" /></label>
        <label className="fitness-module__field">Type<select value={gearType} onChange={(event) => setGearType(event.target.value)}><option value="running_shoe">Running shoe</option><option value="walking_shoe">Walking shoe</option><option value="bike">Bike</option><option value="wearable">Wearable</option><option value="rowing_shell">Rowing shell</option><option value="other">Other</option></select></label>
        <label className="fitness-module__field">Brand<input value={brand} onChange={(event) => setBrand(event.target.value)} /></label>
        <label className="fitness-module__field">Model<input value={model} onChange={(event) => setModel(event.target.value)} /></label>
        <label className="fitness-module__field">Started using<input type="date" value={startedAt} onChange={(event) => setStartedAt(event.target.value)} /></label>
        <label className="fitness-module__field">Usual for<select value={defaultSport} onChange={(event) => setDefaultSport(event.target.value)}><option value="">No default</option><option value="running">Running</option><option value="walking">Walking</option><option value="cycling">Cycling</option></select></label>
      </div>
      <button type="submit" className="button button--primary" disabled={busyId !== null || !name.trim()}><Plus aria-hidden="true" size={16} /> Add gear</button>
    </form>
    {error ? <div className="fitness-module__notice fitness-module__notice--error" role="alert">{error}</div> : null}
    {items.length ? <ul className="fitness-module__list">{items.map((item) => <li key={item.id}><div><strong>{item.name}</strong><small>{[item.brand, item.model, item.activity_count != null ? `${item.activity_count} activities` : null, item.usage_distance_m != null ? `${(item.usage_distance_m / 1000).toFixed(0)} km` : null].filter(Boolean).join(" · ")}</small></div><div className="fitness-module__button-row">{item.default_for_sport_key ? <span className="fitness-module__pill is-neutral"><Star aria-hidden="true" size={13} /> {item.default_for_sport_key}</span> : <button type="button" className="button button--secondary" disabled={busyId !== null} onClick={() => void setDefault(item, item.gear_type_key === "walking_shoe" ? "walking" : item.gear_type_key === "bike" ? "cycling" : "running")}><Footprints aria-hidden="true" size={15} /> Make usual</button>}<button type="button" className="button button--secondary" aria-label={`Remove ${item.name}`} disabled={busyId !== null} onClick={() => void remove(item)}><Trash2 aria-hidden="true" size={15} /></button></div></li>)}</ul> : null}
    <button type="button" className="button button--secondary" onClick={onClose}>Close gear manager</button>
  </FitnessCard>;
}
