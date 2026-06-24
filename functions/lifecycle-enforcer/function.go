package lifecycle

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/GoogleCloudPlatform/functions-framework-go/functions"
	"google.golang.org/api/compute/v1"
	"google.golang.org/api/container/v1"
)

func init() {
	functions.HTTP("EnforceLifecycle", handleEnforceLifecycle)
}

func handleEnforceLifecycle(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ctx := r.Context()
	logger := slog.Default()
	now := time.Now().UTC()

	projectID := os.Getenv("PROJECT_ID")
	if projectID == "" {
		logger.Error("PROJECT_ID environment variable is required")
		http.Error(w, "PROJECT_ID environment variable is required", http.StatusInternalServerError)
		return
	}

	dryRun := os.Getenv("DRY_RUN") != "false"

	logger.Info("starting lifecycle enforcement",
		"project", projectID,
		"dry_run", dryRun,
		"timestamp", now.Format(time.RFC3339),
	)

	containerSvc, err := container.NewService(ctx)
	if err != nil {
		logger.Error("failed to create container client", "error", err)
		http.Error(w, "failed to create container client", http.StatusInternalServerError)
		return
	}

	computeSvc, err := compute.NewService(ctx)
	if err != nil {
		logger.Error("failed to create compute client", "error", err)
		http.Error(w, "failed to create compute client", http.StatusInternalServerError)
		return
	}

	clusters, err := listClusters(ctx, containerSvc, projectID)
	if err != nil {
		logger.Error("failed to list clusters", "error", err)
		http.Error(w, "failed to list clusters", http.StatusInternalServerError)
		return
	}

	logger.Info("found clusters", "count", len(clusters))

	type result struct {
		Cluster  string `json:"cluster"`
		Action   string `json:"action"`
		Reason   string `json:"reason"`
		Executed bool   `json:"executed"`
		Error    string `json:"error,omitempty"`
	}
	var results []result
	hadFailure := false

	for _, apiCluster := range clusters {
		clusterInfo, err := buildClusterInfo(ctx, computeSvc, projectID, apiCluster)
		if err != nil {
			hadFailure = true
			logger.Error("failed to build cluster info",
				"cluster", apiCluster.Name,
				"error", err,
			)
			results = append(results, result{
				Cluster: apiCluster.Name,
				Action:  "error",
				Reason:  "failed to build cluster info",
				Error:   err.Error(),
			})
			continue
		}

		decision := EvaluateCluster(clusterInfo, now)

		logger.Info("evaluated cluster",
			"cluster", clusterInfo.Name,
			"action", decision.Action.String(),
			"reason", decision.Reason,
		)

		if decision.Action == ActionSkip {
			results = append(results, result{
				Cluster: clusterInfo.Name,
				Action:  decision.Action.String(),
				Reason:  decision.Reason,
			})
			continue
		}

		if dryRun {
			logger.Info("DRY RUN: would execute action",
				"cluster", clusterInfo.Name,
				"action", decision.Action.String(),
				"reason", decision.Reason,
				"set_labels", decision.SetLabels,
			)
			results = append(results, result{
				Cluster:  clusterInfo.Name,
				Action:   decision.Action.String(),
				Reason:   decision.Reason,
				Executed: false,
			})
			continue
		}

		execErr := executeDecision(ctx, containerSvc, projectID, clusterInfo, decision)
		res := result{
			Cluster:  clusterInfo.Name,
			Action:   decision.Action.String(),
			Reason:   decision.Reason,
			Executed: execErr == nil,
		}
		if execErr != nil {
			hadFailure = true
			res.Error = execErr.Error()
			logger.Error("failed to execute action",
				"cluster", clusterInfo.Name,
				"action", decision.Action.String(),
				"error", execErr,
			)
		} else {
			logger.Info("executed action",
				"cluster", clusterInfo.Name,
				"action", decision.Action.String(),
			)
		}
		results = append(results, res)
	}

	w.Header().Set("Content-Type", "application/json")
	status := http.StatusOK
	if hadFailure {
		status = http.StatusInternalServerError
	}
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(map[string]any{
		"timestamp": now.Format(time.RFC3339),
		"project":   projectID,
		"dry_run":   dryRun,
		"results":   results,
	}); err != nil {
		logger.Error("failed to encode response", "error", err)
	}
}

func listClusters(ctx context.Context, svc *container.Service, projectID string) ([]*container.Cluster, error) {
	resp, err := svc.Projects.Locations.Clusters.List("projects/" + projectID + "/locations/-").Context(ctx).Do()
	if err != nil {
		return nil, fmt.Errorf("listing clusters: %w", err)
	}
	return resp.Clusters, nil
}

var igmZoneRegexp = regexp.MustCompile(`/zones/([^/]+)/instanceGroupManagers/([^/]+)`)

func buildClusterInfo(ctx context.Context, computeSvc *compute.Service, projectID string, c *container.Cluster) (ClusterInfo, error) {
	info := ClusterInfo{
		Name:             c.Name,
		Location:         c.Location,
		Labels:           c.ResourceLabels,
		LabelFingerprint: c.LabelFingerprint,
	}

	if info.Labels == nil {
		info.Labels = make(map[string]string)
	}

	for _, np := range c.NodePools {
		npInfo := NodePoolInfo{
			Name: np.Name,
		}

		var totalInstances int32
		for _, igURL := range np.InstanceGroupUrls {
			matches := igmZoneRegexp.FindStringSubmatch(igURL)
			if len(matches) < 3 {
				return ClusterInfo{}, fmt.Errorf("parsing instance group URL for node pool %s/%s: %q", c.Name, np.Name, igURL)
			}
			igZone := matches[1]
			igName := matches[2]

			managed, err := computeSvc.InstanceGroupManagers.ListManagedInstances(projectID, igZone, igName).Context(ctx).Do()
			if err != nil {
				return ClusterInfo{}, fmt.Errorf("listing managed instances for %s/%s: %w", igName, igZone, err)
			}

			totalInstances += int32(len(managed.ManagedInstances))

			for _, mi := range managed.ManagedInstances {
				instanceName := lastSegment(mi.Instance)
				var inst *compute.Instance
				var lastErr error
				for attempt := 0; attempt < 3; attempt++ {
					inst, lastErr = computeSvc.Instances.Get(projectID, igZone, instanceName).Context(ctx).Do()
					if lastErr == nil {
						break
					}
					backoff := time.NewTimer(time.Duration(attempt+1) * 500 * time.Millisecond)
					select {
					case <-ctx.Done():
						backoff.Stop()
						return ClusterInfo{}, fmt.Errorf("getting instance %s details: %w", instanceName, ctx.Err())
					case <-backoff.C:
					}
				}
				if lastErr != nil {
					slog.Warn("failed to get instance details after retries",
						"instance", instanceName,
						"attempts", 3,
						"error", lastErr,
					)
					npInfo.IncompleteNodeInfo = true
					continue
				}

				creationTime, err := time.Parse(time.RFC3339, inst.CreationTimestamp)
				if err != nil {
					npInfo.IncompleteNodeInfo = true
					continue
				}

				npInfo.Nodes = append(npInfo.Nodes, NodeInfo{
					Name:             instanceName,
					CreationTimestamp: creationTime,
				})
			}
		}

		npInfo.NodeCount = totalInstances
		info.NodePools = append(info.NodePools, npInfo)
	}

	return info, nil
}

func executeDecision(ctx context.Context, svc *container.Service, projectID string, cluster ClusterInfo, decision Decision) error {
	clusterPath := fmt.Sprintf("projects/%s/locations/%s/clusters/%s", projectID, cluster.Location, cluster.Name)

	applyLabels := func() error {
		if len(decision.SetLabels) == 0 && len(decision.RemoveLabels) == 0 {
			return nil
		}
		labels := make(map[string]string)
		for k, v := range cluster.Labels {
			labels[k] = v
		}
		for k, v := range decision.SetLabels {
			labels[k] = v
		}
		for _, k := range decision.RemoveLabels {
			delete(labels, k)
		}

		req := &container.SetLabelsRequest{
			ResourceLabels:   labels,
			LabelFingerprint: cluster.LabelFingerprint,
		}
		if _, err := svc.Projects.Locations.Clusters.SetResourceLabels(clusterPath, req).Context(ctx).Do(); err != nil {
			return fmt.Errorf("setting labels on %s: %w", cluster.Name, err)
		}
		slog.Info("updated labels", "cluster", cluster.Name, "labels", decision.SetLabels)
		return nil
	}

	if decision.Action != ActionShutdown {
		if err := applyLabels(); err != nil {
			return err
		}
	}

	switch decision.Action {
	case ActionLabelOnly:
		// labels already applied above

	case ActionShutdown:
		for _, np := range cluster.NodePools {
			if np.NodeCount == 0 {
				continue
			}
			npPath := fmt.Sprintf("%s/nodePools/%s", clusterPath, np.Name)
			req := &container.SetNodePoolSizeRequest{NodeCount: 0}
			if _, err := svc.Projects.Locations.Clusters.NodePools.SetSize(npPath, req).Context(ctx).Do(); err != nil {
				return fmt.Errorf("scaling node pool %s/%s to 0: %w", cluster.Name, np.Name, err)
			}
			slog.Info("scaled node pool to 0", "cluster", cluster.Name, "node_pool", np.Name)
		}
		if err := applyLabels(); err != nil {
			return err
		}

	case ActionDelete:
		if _, err := svc.Projects.Locations.Clusters.Delete(clusterPath).Context(ctx).Do(); err != nil {
			if strings.Contains(err.Error(), "deletion protection") {
				slog.Warn("cannot delete cluster with deletion protection enabled",
					"cluster", cluster.Name,
				)
				return fmt.Errorf("cluster %s has deletion protection enabled", cluster.Name)
			}
			return fmt.Errorf("deleting cluster %s: %w", cluster.Name, err)
		}
		slog.Info("deleted cluster", "cluster", cluster.Name)

	default:
		return fmt.Errorf("unsupported action %q for cluster %s", decision.Action.String(), cluster.Name)
	}

	return nil
}

func lastSegment(url string) string {
	parts := strings.Split(url, "/")
	return parts[len(parts)-1]
}
