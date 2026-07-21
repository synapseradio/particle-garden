import { describe, expect, test } from "bun:test";
import {
  formatMs,
  formatParamValue,
  formatWithThousands,
} from "../src/lib/format";

describe("formatParamValue", () => {
  test("int-kind values truncate to whole numbers", () => {
    expect(formatParamValue(4.9, "int", 0)).toBe("4");
    expect(formatParamValue(16000, "int", 0)).toBe("16000");
  });

  test("precision-zero floats truncate like the old slider display", () => {
    expect(formatParamValue(50.7, "float", 0)).toBe("50");
  });

  test("floats render at their descriptor precision", () => {
    expect(formatParamValue(0.3, "float", 2)).toBe("0.30");
    expect(formatParamValue(1.0, "float", 1)).toBe("1.0");
    expect(formatParamValue(0.062, "float", 3)).toBe("0.062");
  });
});

describe("formatWithThousands", () => {
  test("groups digits in threes with commas", () => {
    expect(formatWithThousands(0)).toBe("0");
    expect(formatWithThousands(999)).toBe("999");
    expect(formatWithThousands(1000)).toBe("1,000");
    expect(formatWithThousands(16000)).toBe("16,000");
    expect(formatWithThousands(128000)).toBe("128,000");
    expect(formatWithThousands(1234567)).toBe("1,234,567");
  });
});

describe("formatMs", () => {
  test("renders at the requested decimal places", () => {
    expect(formatMs(1.234, 2)).toBe("1.23");
    expect(formatMs(1.25, 1)).toBe("1.3");
  });
});
