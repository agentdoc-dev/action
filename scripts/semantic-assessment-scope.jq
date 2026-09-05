($request[0].context.items | map(.handle_id) | unique) as $available
| ($request[0].context.items
    | map(select(.handle.kind == "knowledge_object") | {
        object_id:.handle.object_id,
        content_hash:.handle.semantic_hash
      })
    | unique) as $objects
| .scope.handle_ids as $scope
| (($scope - $available) | length) == 0
  and all(.findings[]; ((.citations - $scope) | length) == 0)
  and all(.findings[].affected_objects[]?; . as $affected
    | any($objects[]; . == $affected))
