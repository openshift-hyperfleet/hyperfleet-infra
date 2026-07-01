package lifecycle

import (
	"strings"
	"time"
)

const (
	LabelEnvironment  = "environment"
	LabelOwner        = "owner"
	LabelTTL          = "ttl"
	LabelShutdownDate = "shutdown-date"

	DateFormat = "2006-01-02"

	IdleThreshold          = 12 * time.Hour
	TTLDeleteGracePeriod   = 48 * time.Hour
	OwnerDeleteGracePeriod = 7 * 24 * time.Hour

	EnvCICD       = "cicd"
	EnvDev        = "dev"
	CIInfraPrefix = "hyperfleet-dev-ci-infra-"
)

type ActionType int

const (
	ActionSkip ActionType = iota
	ActionLabelOnly
	ActionShutdown
	ActionDelete
)

func (a ActionType) String() string {
	switch a {
	case ActionSkip:
		return "skip"
	case ActionLabelOnly:
		return "label-only"
	case ActionShutdown:
		return "shutdown"
	case ActionDelete:
		return "delete"
	default:
		return "unknown"
	}
}

type ClusterInfo struct {
	Name             string
	Location         string
	Labels           map[string]string
	LabelFingerprint string
	NodePools        []NodePoolInfo
}

type NodePoolInfo struct {
	Name               string
	NodeCount          int32
	Nodes              []NodeInfo
	IncompleteNodeInfo bool
}

type NodeInfo struct {
	Name             string
	CreationTimestamp time.Time
}

type Decision struct {
	Action       ActionType
	Reason       string
	SetLabels    map[string]string
	RemoveLabels []string
}

func EvaluateCluster(cluster ClusterInfo, now time.Time) Decision {
	if exempt, reason := isExempt(cluster); exempt {
		return Decision{Action: ActionSkip, Reason: reason}
	}

	hasOwner := cluster.Labels[LabelOwner] != ""

	ttlExpired, hasTTL := isTTLExpired(cluster, now)
	shutdownDate, hasShutdownDate := parseDateLabel(cluster.Labels, LabelShutdownDate)
	scaledDown := isScaledDown(cluster)

	if hasShutdownDate {
		if !hasOwner && now.Sub(shutdownDate) > OwnerDeleteGracePeriod {
			return Decision{Action: ActionDelete, Reason: "missing owner, grace period expired (>7 days)"}
		}
		if hasOwner && (ttlExpired || !hasTTL) && now.Sub(shutdownDate) > TTLDeleteGracePeriod {
			return Decision{Action: ActionDelete, Reason: "TTL expired, grace period expired (>48h)"}
		}
	}

	if !hasOwner {
		return buildEnforcementDecision("missing owner label", scaledDown, hasShutdownDate, now)
	}

	if !hasTTL {
		return buildEnforcementDecision("missing TTL label", scaledDown, hasShutdownDate, now)
	}

	if ttlExpired {
		return buildEnforcementDecision("TTL expired", scaledDown, hasShutdownDate, now)
	}

	if !scaledDown && hasOnlyIdleNodes(cluster, now) {
		return Decision{Action: ActionShutdown, Reason: "idle nodes (running >12h)"}
	}

	if hasShutdownDate {
		return Decision{
			Action:       ActionLabelOnly,
			Reason:       "cluster is healthy, clearing stale shutdown-date",
			RemoveLabels: []string{LabelShutdownDate},
		}
	}

	return Decision{Action: ActionSkip, Reason: "cluster is healthy"}
}

func buildEnforcementDecision(reason string, scaledDown, hasShutdownDate bool, now time.Time) Decision {
	d := Decision{Reason: reason}

	if !scaledDown {
		d.Action = ActionShutdown
		d.SetLabels = map[string]string{LabelShutdownDate: now.Format(DateFormat)}
		return d
	}

	if !hasShutdownDate {
		d.Action = ActionLabelOnly
		d.SetLabels = map[string]string{LabelShutdownDate: now.Format(DateFormat)}
		return d
	}

	d.Action = ActionSkip
	d.Reason = reason + ", already scaled down, within grace period"
	return d
}

func isExempt(cluster ClusterInfo) (bool, string) {
	if strings.HasPrefix(cluster.Name, CIInfraPrefix) {
		return true, "ephemeral CI cluster"
	}

	env := cluster.Labels[LabelEnvironment]
	if env == EnvCICD {
		return true, "environment is cicd"
	}

	if env != EnvDev && env != "" {
		return true, "not a dev cluster (environment=" + env + ")"
	}

	return false, ""
}

func isScaledDown(cluster ClusterInfo) bool {
	for _, np := range cluster.NodePools {
		if np.NodeCount > 0 {
			return false
		}
	}
	return true
}

func hasOnlyIdleNodes(cluster ClusterInfo, now time.Time) bool {
	hasNodes := false
	for _, np := range cluster.NodePools {
		if np.IncompleteNodeInfo {
			return false
		}
		for _, node := range np.Nodes {
			hasNodes = true
			if now.Sub(node.CreationTimestamp) <= IdleThreshold {
				return false
			}
		}
	}
	return hasNodes
}

func isTTLExpired(cluster ClusterInfo, now time.Time) (expired bool, hasTTL bool) {
	ttlStr, ok := cluster.Labels[LabelTTL]
	if !ok || ttlStr == "" {
		return false, false
	}

	ttlDate, err := time.Parse(DateFormat, ttlStr)
	if err != nil {
		return true, true
	}

	return now.After(ttlDate), true
}

func parseDateLabel(labels map[string]string, key string) (time.Time, bool) {
	val, ok := labels[key]
	if !ok || val == "" {
		return time.Time{}, false
	}

	t, err := time.Parse(DateFormat, val)
	if err != nil {
		return time.Time{}, false
	}

	return t, true
}
