import axios from "axios";

const API_BASE = process.env.REACT_APP_API_BASE || "http://localhost:8000";
export const WS_BASE = process.env.REACT_APP_WS_BASE || "ws://localhost:8000/ws";

export async function fetchModules() {
  const { data } = await axios.get(`${API_BASE}/modules`);
  return data;
}

export async function generatePipeline(pipeline) {
  const { data } = await axios.post(`${API_BASE}/pipelines`, pipeline);
  return data;
}

export async function fetchPipelineStatus(pipelineId) {
  const { data } = await axios.get(`${API_BASE}/pipelines/${pipelineId}/status`);
  return data;
}

export { API_BASE };
