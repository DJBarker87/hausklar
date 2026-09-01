import { Component, type ErrorInfo, type ReactNode } from "react";

import { ErrorState } from "./ui";

export class RouteErrorBoundary extends Component<
  { children: ReactNode; resetKey: string },
  { failed: boolean }
> {
  state = { failed: false };

  static getDerivedStateFromError() {
    return { failed: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("HausKlar route render failed", error, info.componentStack);
  }

  componentDidUpdate(previous: Readonly<{ children: ReactNode; resetKey: string }>) {
    if (previous.resetKey !== this.props.resetKey && this.state.failed) {
      this.setState({ failed: false });
    }
  }

  render() {
    if (this.state.failed) {
      return (
        <ErrorState
          message="This section hit an unexpected problem. Your other HausKlar areas are still available."
          retry={() => this.setState({ failed: false })}
        />
      );
    }
    return this.props.children;
  }
}
