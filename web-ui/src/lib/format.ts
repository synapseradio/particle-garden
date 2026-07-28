// Display formatting for values the Nim side hands over as raw numbers.
// Int-kind and precision-0 values truncate, float values
// render at their descriptor precision, particle counts take comma
// separators deterministically (no locale dependence).

import type { ParamKind } from "../garden-api";

export function formatParamValue(
  value: number,
  kind: ParamKind,
  precision: number,
): string {
  if (kind === "int" || precision <= 0) return String(Math.trunc(value));
  return value.toFixed(precision);
}

export function formatWithThousands(count: number): string {
  const digits = String(Math.trunc(Math.abs(count)));
  let grouped = "";
  for (let index = 0; index < digits.length; index += 1) {
    const remaining = digits.length - index;
    if (index > 0 && remaining % 3 === 0) grouped += ",";
    grouped += digits[index];
  }
  return count < 0 ? `-${grouped}` : grouped;
}

export function formatMs(ms: number, decimals: number): string {
  return ms.toFixed(decimals);
}
