"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";

type Subscription = {
  id: string;
  name: string;
  cost: number;
  cadence: "monthly" | "yearly";
};

type Plan = {
  currency: string;
  cash: number;
  investments: number;
  annualReturn: number;
  monthlyIncome: number;
  monthlyEssentials: number;
  protectedCash: number;
  horizonYears: number;
  candidateCost: number;
  subscriptions: Subscription[];
};

const DEFAULT_PLAN: Plan = {
  currency: "USD",
  cash: 0,
  investments: 0,
  annualReturn: 5,
  monthlyIncome: 0,
  monthlyEssentials: 0,
  protectedCash: 0,
  horizonYears: 30,
  candidateCost: 0,
  subscriptions: [],
};

const CURRENCIES = ["USD", "EUR", "GBP", "CAD", "AUD"];

function monthlyCost(subscription: Subscription) {
  return subscription.cadence === "yearly"
    ? subscription.cost / 12
    : subscription.cost;
}

function paymentFromAssets(principal: number, monthlyRate: number, months: number) {
  if (principal <= 0 || months <= 0) return 0;
  if (Math.abs(monthlyRate) < 0.0000001) return principal / months;
  const denominator = 1 - Math.pow(1 + monthlyRate, -months);
  return denominator === 0 ? 0 : (principal * monthlyRate) / denominator;
}

function numberValue(value: string) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function projectBalance(
  startingAssets: number,
  monthlyRate: number,
  monthlyNet: number,
  months: number,
) {
  let balance = startingAssets;
  for (let month = 0; month < months; month += 1) {
    balance = balance * (1 + monthlyRate) + monthlyNet;
  }
  return balance;
}

export default function Home() {
  const [plan, setPlan] = useState<Plan>(DEFAULT_PLAN);
  const [loaded, setLoaded] = useState(false);
  const [newName, setNewName] = useState("");
  const [newCost, setNewCost] = useState("");
  const [newCadence, setNewCadence] =
    useState<Subscription["cadence"]>("monthly");

  useEffect(() => {
    const saved = window.localStorage.getItem("can-i-afford-this-plan");
    if (saved) {
      try {
        setPlan({ ...DEFAULT_PLAN, ...JSON.parse(saved) });
      } catch {
        window.localStorage.removeItem("can-i-afford-this-plan");
      }
    }
    setLoaded(true);
  }, []);

  useEffect(() => {
    if (loaded) {
      window.localStorage.setItem("can-i-afford-this-plan", JSON.stringify(plan));
    }
  }, [loaded, plan]);

  const results = useMemo(() => {
    const recurring = plan.subscriptions.reduce(
      (sum, item) => sum + monthlyCost(item),
      0,
    );
    const startingAssets = Math.max(0, plan.cash + plan.investments);
    const spendableAssets = Math.max(0, startingAssets - plan.protectedCash);
    const months = Math.max(1, Math.round(plan.horizonYears * 12));
    const monthlyRate = Math.pow(1 + plan.annualReturn / 100, 1 / 12) - 1;
    const assetSupport = paymentFromAssets(spendableAssets, monthlyRate, months);
    const sustainableBudget = Math.max(
      0,
      plan.monthlyIncome - plan.monthlyEssentials + assetSupport,
    );
    const currentHeadroom = sustainableBudget - recurring;
    const afterCandidate = currentHeadroom - plan.candidateCost;
    const operatingNet =
      plan.monthlyIncome -
      plan.monthlyEssentials -
      recurring -
      plan.candidateCost;
    const projectedEnd = projectBalance(
      startingAssets,
      monthlyRate,
      operatingNet,
      months,
    );
    const essentialMonths =
      plan.monthlyEssentials + recurring > 0
        ? startingAssets / (plan.monthlyEssentials + recurring)
        : null;

    return {
      recurring,
      startingAssets,
      sustainableBudget,
      currentHeadroom,
      afterCandidate,
      projectedEnd,
      essentialMonths,
      assetSupport,
    };
  }, [plan]);

  const money = useMemo(
    () =>
      new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: plan.currency,
        maximumFractionDigits: 0,
      }),
    [plan.currency],
  );

  const moneyPrecise = useMemo(
    () =>
      new Intl.NumberFormat(undefined, {
        style: "currency",
        currency: plan.currency,
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      }),
    [plan.currency],
  );

  function update<K extends keyof Plan>(key: K, value: Plan[K]) {
    setPlan((current) => ({ ...current, [key]: value }));
  }

  function addSubscription(event: FormEvent) {
    event.preventDefault();
    const cost = numberValue(newCost);
    if (!newName.trim() || cost <= 0) return;
    update("subscriptions", [
      ...plan.subscriptions,
      {
        id: crypto.randomUUID(),
        name: newName.trim(),
        cost,
        cadence: newCadence,
      },
    ]);
    setNewName("");
    setNewCost("");
  }

  const verdict =
    plan.candidateCost <= 0
      ? {
          label: "Enter a monthly cost",
          detail: "Use the test field to check a subscription or payment.",
          tone: "neutral",
        }
      : results.afterCandidate >= 0
        ? {
            label: "Yes, it fits",
            detail: `${money.format(results.afterCandidate)} remains in your sustainable monthly budget.`,
            tone: "good",
          }
        : {
            label: "Not sustainably",
            detail: `It exceeds your monthly limit by ${money.format(Math.abs(results.afterCandidate))}.`,
            tone: "bad",
          };

  return (
    <main>
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">CA</span>
          <div>
            <p className="kicker">Personal runway</p>
            <h1>Can I afford this?</h1>
          </div>
        </div>
        <div className="privacy-note">
          <span className="privacy-dot" aria-hidden="true" />
          Saved only on this device
        </div>
      </header>

      <section className="verdict-grid" aria-label="Affordability summary">
        <div className={`verdict-panel ${verdict.tone}`}>
          <p className="kicker">Monthly decision</p>
          <div className="verdict-row">
            <div>
              <p className="verdict-label">{verdict.label}</p>
              <p className="verdict-detail">{verdict.detail}</p>
            </div>
            <label className="test-cost">
              <span>Test a monthly cost</span>
              <span className="money-input">
                <span>{money.formatToParts(0).find((part) => part.type === "currency")?.value}</span>
                <input
                  inputMode="decimal"
                  type="number"
                  min="0"
                  step="1"
                  value={plan.candidateCost || ""}
                  onChange={(event) =>
                    update("candidateCost", Math.max(0, numberValue(event.target.value)))
                  }
                  aria-label="Monthly cost to test"
                />
              </span>
            </label>
          </div>
        </div>

        <div className="metric-panel">
          <p className="kicker">Sustainable room</p>
          <p className={`hero-number ${results.currentHeadroom < 0 ? "negative" : ""}`}>
            {money.format(results.currentHeadroom)}
          </p>
          <p className="metric-caption">available per month before the test cost</p>
          <div className="capacity-bar" aria-hidden="true">
            <span
              style={{
                width: `${Math.max(0, Math.min(100, results.sustainableBudget > 0 ? (results.recurring / results.sustainableBudget) * 100 : 0))}%`,
              }}
            />
          </div>
          <div className="capacity-labels">
            <span>{money.format(results.recurring)} committed</span>
            <span>{money.format(results.sustainableBudget)} limit</span>
          </div>
        </div>
      </section>

      <div className="workspace">
        <section className="panel inputs-panel">
          <div className="section-heading">
            <div>
              <p className="kicker">Your baseline</p>
              <h2>Money and assumptions</h2>
            </div>
            <label className="currency-select">
              <span className="sr-only">Currency</span>
              <select
                value={plan.currency}
                onChange={(event) => update("currency", event.target.value)}
              >
                {CURRENCIES.map((currency) => (
                  <option key={currency}>{currency}</option>
                ))}
              </select>
            </label>
          </div>

          <div className="field-grid">
            <NumberField label="Cash" value={plan.cash} onChange={(value) => update("cash", value)} prefix={money} />
            <NumberField label="Investments" value={plan.investments} onChange={(value) => update("investments", value)} prefix={money} />
            <NumberField label="Expected monthly income" value={plan.monthlyIncome} onChange={(value) => update("monthlyIncome", value)} prefix={money} />
            <NumberField label="Essential monthly spending" value={plan.monthlyEssentials} onChange={(value) => update("monthlyEssentials", value)} prefix={money} />
            <NumberField label="Cash you will not touch" value={plan.protectedCash} onChange={(value) => update("protectedCash", value)} prefix={money} />
            <NumberField label="Expected annual return" value={plan.annualReturn} onChange={(value) => update("annualReturn", Math.max(-99, Math.min(50, value)))} suffix="%" step="0.1" />
          </div>

          <label className="horizon-control">
            <span>
              <strong>Planning horizon</strong>
              <small>How long this money should support your spending</small>
            </span>
            <span className="horizon-value">{plan.horizonYears} years</span>
            <input
              type="range"
              min="1"
              max="60"
              value={plan.horizonYears}
              onChange={(event) => update("horizonYears", numberValue(event.target.value))}
            />
          </label>
        </section>

        <section className="panel subscriptions-panel">
          <div className="section-heading">
            <div>
              <p className="kicker">Recurring costs</p>
              <h2>Subscriptions & payments</h2>
            </div>
            <p className="section-total">{moneyPrecise.format(results.recurring)}<span>/mo</span></p>
          </div>

          <form className="add-form" onSubmit={addSubscription}>
            <label>
              <span className="sr-only">Subscription name</span>
              <input
                type="text"
                placeholder="Name"
                value={newName}
                onChange={(event) => setNewName(event.target.value)}
              />
            </label>
            <label>
              <span className="sr-only">Subscription cost</span>
              <input
                type="number"
                inputMode="decimal"
                min="0"
                step="0.01"
                placeholder="Cost"
                value={newCost}
                onChange={(event) => setNewCost(event.target.value)}
              />
            </label>
            <label>
              <span className="sr-only">Billing frequency</span>
              <select
                value={newCadence}
                onChange={(event) =>
                  setNewCadence(event.target.value as Subscription["cadence"])
                }
              >
                <option value="monthly">Monthly</option>
                <option value="yearly">Yearly</option>
              </select>
            </label>
            <button type="submit">Add</button>
          </form>

          {plan.subscriptions.length ? (
            <ul className="subscription-list">
              {plan.subscriptions.map((subscription) => (
                <li key={subscription.id}>
                  <div>
                    <strong>{subscription.name}</strong>
                    <span>
                      {moneyPrecise.format(subscription.cost)} billed {subscription.cadence}
                    </span>
                  </div>
                  <p>{moneyPrecise.format(monthlyCost(subscription))}<span>/mo</span></p>
                  <button
                    type="button"
                    className="remove-button"
                    onClick={() =>
                      update(
                        "subscriptions",
                        plan.subscriptions.filter((item) => item.id !== subscription.id),
                      )
                    }
                    aria-label={`Remove ${subscription.name}`}
                  >
                    ×
                  </button>
                </li>
              ))}
            </ul>
          ) : (
            <div className="empty-state">
              <p>No recurring costs added yet.</p>
              <span>Add monthly or yearly payments above. Yearly costs are converted automatically.</span>
            </div>
          )}
        </section>
      </div>

      <section className="analysis-strip" aria-label="Long-term analysis">
        <div>
          <p className="kicker">What your assets add</p>
          <p className="analysis-number">{money.format(results.assetSupport)}<span>/mo</span></p>
          <p>Potential monthly support from assets above your protected cash over {plan.horizonYears} years.</p>
        </div>
        <div>
          <p className="kicker">Projected balance</p>
          <p className={`analysis-number ${results.projectedEnd < 0 ? "negative" : ""}`}>
            {money.format(results.projectedEnd)}
          </p>
          <p>Estimated assets after {plan.horizonYears} years with the tested cost included.</p>
        </div>
        <div>
          <p className="kicker">Current runway</p>
          <p className="analysis-number">
            {results.essentialMonths === null
              ? "—"
              : `${results.essentialMonths.toFixed(results.essentialMonths < 10 ? 1 : 0)} mo`}
          </p>
          <p>How long current assets cover essentials and existing recurring costs, ignoring income and returns.</p>
        </div>
      </section>

      <footer>
        <p>
          This is a planning estimate, not financial advice. Returns are uncertain, taxes and inflation are not modeled, and all values stay in this browser.
        </p>
        <button
          type="button"
          onClick={() => {
            if (window.confirm("Clear all saved values on this device?")) {
              setPlan(DEFAULT_PLAN);
            }
          }}
        >
          Reset all data
        </button>
      </footer>
    </main>
  );
}

function NumberField({
  label,
  value,
  onChange,
  prefix,
  suffix,
  step = "1",
}: {
  label: string;
  value: number;
  onChange: (value: number) => void;
  prefix?: Intl.NumberFormat;
  suffix?: string;
  step?: string;
}) {
  const symbol = prefix
    ?.formatToParts(0)
    .find((part) => part.type === "currency")?.value;

  return (
    <label className="number-field">
      <span>{label}</span>
      <span className="number-input">
        {symbol && <span>{symbol}</span>}
        <input
          type="number"
          inputMode="decimal"
          min={suffix ? "-99" : "0"}
          step={step}
          value={value || ""}
          onChange={(event) => onChange(numberValue(event.target.value))}
        />
        {suffix && <span>{suffix}</span>}
      </span>
    </label>
  );
}
