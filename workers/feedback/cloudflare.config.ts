export default {
  worker: {
    name: "jxuc-feedback-worker",
    entrypoint: "src/index.js",
    compatibilityDate: "2025-01-01",
    domains: ["feedback.fhfanshu.xyz"],
    env: {
      GITHUB_OWNER: { type: "text", value: "CampusHub-JXU" },
      GITHUB_REPO: { type: "text", value: "ZJXU-CampusHub" },
      PAUSE_SUBMISSIONS: { type: "text", value: "false" },
    },
  },
};
