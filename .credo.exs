%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/"], excluded: []},
      strict: true,
      checks: %{
        enabled: [
          # Section 21.1 forbids `authorize?: false` outside migrations, seeds,
          # and narrowly reviewed maintenance code, and Section 35 forbids
          # placeholder authorization. Both are grep-shaped rules, so CI runs
          # them as a dedicated check script rather than as a Credo check.
          {Credo.Check.Readability.Specs, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Design.TagTODO, [exit_status: 2]},
          {Credo.Check.Design.TagFIXME, [exit_status: 2]}
        ],
        disabled: [
          {Credo.Check.Readability.ModuleDoc, []}
        ]
      }
    }
  ]
}
