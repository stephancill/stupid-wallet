import React from "react";

type ModalFrameProps = {
  title: string;
  children: React.ReactNode;
  primaryLabel: string;
  secondaryLabel: string;
  onPrimary: () => void;
  onSecondary: () => void;
};

export function ModalFrame(props: ModalFrameProps) {
  const {
    title,
    children,
    primaryLabel,
    secondaryLabel,
    onPrimary,
    onSecondary,
  } = props;
  return (
    <div>
      <div className="backdrop" />
      <div className="panel" role="dialog" aria-modal="true" aria-label={title}>
        <div className="header">{title}</div>
        <div className="body">{children}</div>
        <div className="foot">
          <button className="btn btn-secondary" onClick={onSecondary}>
            {secondaryLabel}
          </button>
          <button className="btn btn-primary" onClick={onPrimary}>
            {primaryLabel}
          </button>
        </div>
      </div>
    </div>
  );
}
