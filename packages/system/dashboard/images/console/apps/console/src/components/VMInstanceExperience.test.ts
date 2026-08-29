import { describe, expect, it } from "vitest"
import { getChangedVmFields, getVmNameError } from "./VMInstanceExperience.tsx"

describe("getVmNameError", () => {
  it("accepts Kubernetes-safe VM names", () => {
    expect(getVmNameError("web-01")).toBeNull()
    expect(getVmNameError("prod.vm-2")).toBeNull()
  })

  it("rejects empty, padded, uppercase and malformed names", () => {
    expect(getVmNameError("")).toBe("Enter a VM name.")
    expect(getVmNameError(" web-01")).toContain("spaces")
    expect(getVmNameError("Web-01")).toContain("lowercase")
    expect(getVmNameError("-web")).toContain("lowercase")
    expect(getVmNameError("web-")).toContain("lowercase")
    expect(getVmNameError("prod..web")).toContain("lowercase")
    expect(getVmNameError("prod-.web")).toContain("lowercase")
  })

  it("enforces the Kubernetes DNS subdomain length limit", () => {
    expect(getVmNameError("a".repeat(253))).toBeNull()
    expect(getVmNameError("a".repeat(254))).toContain("253")
  })
})

describe("getChangedVmFields", () => {
  it("reports only changed top-level VM configuration areas", () => {
    const initial = {
      instanceType: "u1.medium",
      instanceProfile: "ubuntu",
      disks: [{ name: "root" }],
      sshKeys: ["ssh-ed25519 AAAA"],
    }
    const current = {
      instanceType: "u1.large",
      instanceProfile: "ubuntu",
      disks: [{ name: "root" }, { name: "data" }],
      sshKeys: ["ssh-ed25519 AAAA"],
    }

    expect(getChangedVmFields(initial, current)).toEqual(["instanceType", "disks"])
  })

  it("returns no changes for an untouched edit", () => {
    const spec = {
      instanceProfile: "windows",
      networks: [{ name: "prod" }],
      external: false,
    }

    expect(getChangedVmFields(spec, structuredClone(spec))).toEqual([])
  })

  it("keeps future schema fields visible in the change review", () => {
    expect(getChangedVmFields({ futureSetting: false }, { futureSetting: true })).toEqual([
      "futureSetting",
    ])
  })
})
