package lifecycle

import (
	"testing"
	"time"
)

func date(s string) time.Time {
	t, err := time.Parse(DateFormat, s)
	if err != nil {
		panic("invalid test date: " + s)
	}
	return t
}

func nodeAt(created time.Time) NodeInfo {
	return NodeInfo{Name: "node-1", CreationTimestamp: created}
}

func TestEvaluateCluster(t *testing.T) {
	now := date("2026-06-24")

	tests := []struct {
		name           string
		cluster        ClusterInfo
		expectedAction ActionType
		expectedReason string
	}{
		{
			name: "skip: cicd environment",
			cluster: ClusterInfo{
				Name:   "hyperfleet-dev-prow",
				Labels: map[string]string{LabelEnvironment: EnvCICD, LabelOwner: "prow"},
			},
			expectedAction: ActionSkip,
			expectedReason: "environment is cicd",
		},
		{
			name: "skip: ephemeral CI cluster",
			cluster: ClusterInfo{
				Name:   "hyperfleet-dev-ci-infra-abc123",
				Labels: map[string]string{LabelEnvironment: EnvDev, LabelOwner: "ci"},
			},
			expectedAction: ActionSkip,
			expectedReason: "ephemeral CI cluster",
		},
		{
			name: "skip: non-dev environment",
			cluster: ClusterInfo{
				Name:   "hyperfleet-staging",
				Labels: map[string]string{LabelEnvironment: "staging", LabelOwner: "ops"},
			},
			expectedAction: ActionSkip,
			expectedReason: "not a dev cluster (environment=staging)",
		},
		{
			name: "skip: healthy cluster with valid TTL",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-2 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "cluster is healthy",
		},
		{
			name: "skip: already scaled down, missing owner, within grace period",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-unknown",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelShutdownDate: "2026-06-22",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "missing owner label, already scaled down, within grace period",
		},
		{
			name: "skip: already scaled down, TTL expired, within grace period",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelOwner:        "jsmith",
					LabelTTL:          "2026-06-20",
					LabelShutdownDate: "2026-06-23",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "TTL expired, already scaled down, within grace period",
		},
		{
			name: "shutdown: missing owner, first detection",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-orphan",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "missing owner label",
		},
		{
			name: "shutdown: TTL expired, first detection",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "TTL expired",
		},
		{
			name: "shutdown: missing TTL label",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "missing TTL label",
		},
		{
			name: "shutdown: invalid TTL format",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "not-a-date",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "TTL expired",
		},
		{
			name: "shutdown: idle nodes running >12h",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-13 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "idle nodes (running >12h)",
		},
		{
			name: "skip: nodes running <12h (not idle)",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-11 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "cluster is healthy",
		},
		{
			name: "skip: mixed node ages, one fresh node prevents idle shutdown",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 2, Nodes: []NodeInfo{
						nodeAt(now.Add(-20 * time.Hour)),
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "cluster is healthy",
		},
		{
			name: "delete: missing owner, shutdown-date >7 days ago",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-orphan",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelTTL:          "2026-06-10",
					LabelShutdownDate: "2026-06-15",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionDelete,
			expectedReason: "missing owner, grace period expired (>7 days)",
		},
		{
			name: "delete: TTL expired, shutdown-date >48h ago",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelOwner:        "jsmith",
					LabelTTL:          "2026-06-18",
					LabelShutdownDate: "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionDelete,
			expectedReason: "TTL expired, grace period expired (>48h)",
		},
		{
			name: "delete: missing TTL with owner, shutdown-date >48h ago",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelOwner:        "jsmith",
					LabelShutdownDate: "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionDelete,
			expectedReason: "TTL expired, grace period expired (>48h)",
		},
		{
			name: "no TTL delete when owner also missing, uses 7-day grace instead",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-orphan",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelShutdownDate: "2026-06-21",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionSkip,
			expectedReason: "missing owner label, already scaled down, within grace period",
		},
		{
			name: "label-only: missing owner, already scaled down, no shutdown-date yet",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-orphan",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionLabelOnly,
			expectedReason: "missing owner label",
		},
		{
			name: "label-only: TTL expired, already scaled down, no shutdown-date yet",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expectedAction: ActionLabelOnly,
			expectedReason: "TTL expired",
		},
		{
			name: "shutdown: empty labels, missing owner",
			cluster: ClusterInfo{
				Name:   "hyperfleet-dev-mystery",
				Labels: map[string]string{},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "missing owner label",
		},
		{
			name: "skip: no node pools",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{},
			},
			expectedAction: ActionSkip,
			expectedReason: "cluster is healthy",
		},
		{
			name: "label-only: healthy cluster clears stale shutdown-date",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment:  EnvDev,
					LabelOwner:        "jsmith",
					LabelTTL:          "2026-06-29",
					LabelShutdownDate: "2026-06-15",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-2 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionLabelOnly,
			expectedReason: "cluster is healthy, clearing stale shutdown-date",
		},
		{
			name: "shutdown: TTL expired, verify action and reason",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expectedAction: ActionShutdown,
			expectedReason: "TTL expired",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			decision := EvaluateCluster(tt.cluster, now)

			if decision.Action != tt.expectedAction {
				t.Errorf("action: got %s, want %s", decision.Action, tt.expectedAction)
			}
			if decision.Reason != tt.expectedReason {
				t.Errorf("reason: got %q, want %q", decision.Reason, tt.expectedReason)
			}
		})
	}
}

func TestShutdownSetsLabels(t *testing.T) {
	now := date("2026-06-24")

	tests := []struct {
		name          string
		cluster       ClusterInfo
		expectLabels  bool
		expectedLabel string
	}{
		{
			name: "TTL expired shutdown sets shutdown-date",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-20",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-1 * time.Hour))}},
				},
			},
			expectLabels:  true,
			expectedLabel: "2026-06-24",
		},
		{
			name: "missing owner shutdown sets shutdown-date",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-orphan",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-1 * time.Hour))}},
				},
			},
			expectLabels:  true,
			expectedLabel: "2026-06-24",
		},
		{
			name: "idle shutdown does NOT set shutdown-date",
			cluster: ClusterInfo{
				Name: "hyperfleet-dev-jsmith",
				Labels: map[string]string{
					LabelEnvironment: EnvDev,
					LabelOwner:       "jsmith",
					LabelTTL:         "2026-06-29",
				},
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-13 * time.Hour))}},
				},
			},
			expectLabels: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			decision := EvaluateCluster(tt.cluster, now)

			if tt.expectLabels {
				if decision.SetLabels == nil {
					t.Fatal("expected SetLabels to be set")
				}
				if got := decision.SetLabels[LabelShutdownDate]; got != tt.expectedLabel {
					t.Errorf("shutdown-date label: got %q, want %q", got, tt.expectedLabel)
				}
			} else {
				if decision.SetLabels != nil {
					t.Errorf("expected no SetLabels, got %v", decision.SetLabels)
				}
			}
		})
	}
}

func TestHealthyClusterClearsShutdownDate(t *testing.T) {
	now := date("2026-06-24")

	t.Run("healthy cluster with stale shutdown-date requests removal", func(t *testing.T) {
		cluster := ClusterInfo{
			Name: "hyperfleet-dev-jsmith",
			Labels: map[string]string{
				LabelEnvironment:  EnvDev,
				LabelOwner:        "jsmith",
				LabelTTL:          "2026-06-29",
				LabelShutdownDate: "2026-06-15",
			},
			NodePools: []NodePoolInfo{
				{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
					nodeAt(now.Add(-2 * time.Hour)),
				}},
			},
		}

		decision := EvaluateCluster(cluster, now)

		if decision.Action != ActionLabelOnly {
			t.Errorf("action: got %s, want %s", decision.Action, ActionLabelOnly)
		}
		if len(decision.RemoveLabels) != 1 || decision.RemoveLabels[0] != LabelShutdownDate {
			t.Errorf("RemoveLabels: got %v, want [%s]", decision.RemoveLabels, LabelShutdownDate)
		}
	})

	t.Run("healthy cluster without shutdown-date skips", func(t *testing.T) {
		cluster := ClusterInfo{
			Name: "hyperfleet-dev-jsmith",
			Labels: map[string]string{
				LabelEnvironment: EnvDev,
				LabelOwner:       "jsmith",
				LabelTTL:         "2026-06-29",
			},
			NodePools: []NodePoolInfo{
				{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
					nodeAt(now.Add(-2 * time.Hour)),
				}},
			},
		}

		decision := EvaluateCluster(cluster, now)

		if decision.Action != ActionSkip {
			t.Errorf("action: got %s, want %s", decision.Action, ActionSkip)
		}
		if decision.RemoveLabels != nil {
			t.Errorf("RemoveLabels: got %v, want nil", decision.RemoveLabels)
		}
	})

	t.Run("renewed TTL with stale shutdown-date does not trigger immediate deletion", func(t *testing.T) {
		cluster := ClusterInfo{
			Name: "hyperfleet-dev-jsmith",
			Labels: map[string]string{
				LabelEnvironment:  EnvDev,
				LabelOwner:        "jsmith",
				LabelTTL:          "2026-06-29",
				LabelShutdownDate: "2026-06-10",
			},
			NodePools: []NodePoolInfo{
				{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
					nodeAt(now.Add(-2 * time.Hour)),
				}},
			},
		}

		decision := EvaluateCluster(cluster, now)

		if decision.Action == ActionDelete {
			t.Error("should NOT delete — TTL is valid, shutdown-date should be cleared instead")
		}
		if decision.Action != ActionLabelOnly {
			t.Errorf("action: got %s, want %s (to clear stale shutdown-date)", decision.Action, ActionLabelOnly)
		}
	})
}

func TestIsExempt(t *testing.T) {
	tests := []struct {
		name     string
		cluster  ClusterInfo
		expected bool
	}{
		{
			name:     "cicd environment",
			cluster:  ClusterInfo{Name: "hyperfleet-dev-prow", Labels: map[string]string{LabelEnvironment: EnvCICD}},
			expected: true,
		},
		{
			name:     "ci-infra prefix",
			cluster:  ClusterInfo{Name: "hyperfleet-dev-ci-infra-xyz", Labels: map[string]string{LabelEnvironment: EnvDev}},
			expected: true,
		},
		{
			name:     "staging environment",
			cluster:  ClusterInfo{Name: "hyperfleet-staging", Labels: map[string]string{LabelEnvironment: "staging"}},
			expected: true,
		},
		{
			name:     "dev environment",
			cluster:  ClusterInfo{Name: "hyperfleet-dev-jsmith", Labels: map[string]string{LabelEnvironment: EnvDev}},
			expected: false,
		},
		{
			name:     "no environment label",
			cluster:  ClusterInfo{Name: "hyperfleet-dev-jsmith", Labels: map[string]string{}},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			exempt, _ := isExempt(tt.cluster)
			if exempt != tt.expected {
				t.Errorf("isExempt: got %v, want %v", exempt, tt.expected)
			}
		})
	}
}

func TestHasOnlyIdleNodes(t *testing.T) {
	now := date("2026-06-24")

	tests := []struct {
		name     string
		cluster  ClusterInfo
		expected bool
	}{
		{
			name: "all nodes idle (>12h)",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 2, Nodes: []NodeInfo{
						nodeAt(now.Add(-13 * time.Hour)),
						nodeAt(now.Add(-14 * time.Hour)),
					}},
				},
			},
			expected: true,
		},
		{
			name: "one fresh node",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 2, Nodes: []NodeInfo{
						nodeAt(now.Add(-13 * time.Hour)),
						nodeAt(now.Add(-1 * time.Hour)),
					}},
				},
			},
			expected: false,
		},
		{
			name: "no nodes (scaled down)",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 0},
				},
			},
			expected: false,
		},
		{
			name: "node at exactly 12h boundary",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{
						nodeAt(now.Add(-12 * time.Hour)),
					}},
				},
			},
			expected: false,
		},
		{
			name: "multiple pools, all idle",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-15 * time.Hour))}},
					{Name: "pool-2", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-20 * time.Hour))}},
				},
			},
			expected: true,
		},
		{
			name: "multiple pools, one has fresh node",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-15 * time.Hour))}},
					{Name: "pool-2", NodeCount: 1, Nodes: []NodeInfo{nodeAt(now.Add(-2 * time.Hour))}},
				},
			},
			expected: false,
		},
		{
			name: "incomplete node info fails closed (not idle)",
			cluster: ClusterInfo{
				NodePools: []NodePoolInfo{
					{Name: "pool-1", NodeCount: 3, IncompleteNodeInfo: true, Nodes: []NodeInfo{
						nodeAt(now.Add(-15 * time.Hour)),
					}},
				},
			},
			expected: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := hasOnlyIdleNodes(tt.cluster, now)
			if got != tt.expected {
				t.Errorf("hasOnlyIdleNodes: got %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestIsTTLExpired(t *testing.T) {
	now := date("2026-06-24")

	tests := []struct {
		name        string
		labels      map[string]string
		wantExpired bool
		wantHasTTL  bool
	}{
		{
			name:        "no TTL label",
			labels:      map[string]string{},
			wantExpired: false,
			wantHasTTL:  false,
		},
		{
			name:        "TTL in the future",
			labels:      map[string]string{LabelTTL: "2026-06-29"},
			wantExpired: false,
			wantHasTTL:  true,
		},
		{
			name:        "TTL today (not expired)",
			labels:      map[string]string{LabelTTL: "2026-06-24"},
			wantExpired: false,
			wantHasTTL:  true,
		},
		{
			name:        "TTL yesterday (expired)",
			labels:      map[string]string{LabelTTL: "2026-06-23"},
			wantExpired: true,
			wantHasTTL:  true,
		},
		{
			name:        "invalid TTL format",
			labels:      map[string]string{LabelTTL: "not-a-date"},
			wantExpired: true,
			wantHasTTL:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cluster := ClusterInfo{Labels: tt.labels}
			expired, hasTTL := isTTLExpired(cluster, now)
			if expired != tt.wantExpired {
				t.Errorf("expired: got %v, want %v", expired, tt.wantExpired)
			}
			if hasTTL != tt.wantHasTTL {
				t.Errorf("hasTTL: got %v, want %v", hasTTL, tt.wantHasTTL)
			}
		})
	}
}
