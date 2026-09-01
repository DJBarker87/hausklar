import { render, screen } from "@testing-library/react";
import { expect, it } from "vitest";

import type { FinanceSpace } from "../types";
import { FinanceCapturePanel } from "../views/FinanceCapturePanel";

const personal: FinanceSpace = {
  id: "personal-space",
  kind: "personal",
  name: "Alex private",
  is_default: true,
};

const household: FinanceSpace = {
  id: "household-space",
  kind: "household",
  name: "Household",
  is_default: false,
};

it("offers private file upload only inside a personal Finance space", () => {
  const view = render(
    <FinanceCapturePanel
      spaces={[household]}
      accounts={[]}
      locale="en"
      conversation={[]}
    />,
  );

  expect(screen.queryByText("Upload a receipt or statement privately")).not.toBeInTheDocument();

  view.rerender(
    <FinanceCapturePanel
      spaces={[personal]}
      accounts={[]}
      locale="en"
      conversation={[]}
    />,
  );

  expect(screen.getByText("Upload a receipt or statement privately")).toBeInTheDocument();
});
