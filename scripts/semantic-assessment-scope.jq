($request[0].context.items | map(.handle_id) | unique) as $available
| .scope.handle_ids as $scope
| (($scope - $available) | length) == 0
  and all(.findings[]; ((.citations - $scope) | length) == 0)
