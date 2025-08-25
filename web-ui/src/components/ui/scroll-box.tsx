import * as React from "react";

import { cn } from "@/lib/utils";

type ScrollBoxProps = React.HTMLAttributes<HTMLDivElement> & {
  maxHeight?: string | number;
};

function ScrollBox({
  className,
  style,
  maxHeight = "50vh",
  ...props
}: ScrollBoxProps) {
  const computedMaxHeight =
    typeof maxHeight === "number" ? `${maxHeight}px` : maxHeight;

  return (
    <div
      className={cn(
        "rounded-md border bg-muted/30 p-3 text-xs overflow-auto",
        className
      )}
      style={{ maxHeight: computedMaxHeight, ...style }}
      {...props}
    />
  );
}

export { ScrollBox };
