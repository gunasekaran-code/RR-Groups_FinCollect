<?php
// Customers reached through rest.php?table=customers.
//   - Read:   admin, everyone. An agent, their own customers plus the ones
//             behind loans, funds and chit groups they hold. A customer,
//             their own record only. Enforced here, in SQL — the line that
//             used to sit on this file said "any authenticated user
//             (frontend scopes rows per role)", which is a hope, not a rule.
//   - Update: admin (any field) or agent (GPS location + KYC document images —
//             the "Visit" button pins location, and agents capture documents in
//             the field; they still can't rename or reassign a customer).
//   - Delete: admin only, and it is a SOFT delete — the row is flagged
//             delflag = 1 rather than removed, because loans, collections,
//             funds and chit membership all reference it. Reads filter
//             delflag = 0 here, in one place, so none of the ~14 screens
//             that list customers can forget to exclude deleted ones.
//   Full create/update with a linked login account goes through customers.php
//   (CustomerController), so POST here is admin-only as a safety net.
//   Customers can never write customer records.

class CustomerRestController extends ResourceController
{
    /**
     * The only customer columns an agent may write.
     *
     * An agent works in the field: the Visit button pins a customer's location,
     * and KYC documents are photographed at the door. Everything that
     * identifies the customer — their name, Aadhaar and PAN numbers, and above
     * all which agent they belong to — stays with an admin. The rule was
     * written down at the top of this file long before it was enforced, so an
     * agent could in fact reassign a customer to themselves through rest.php.
     */

    private const AGENT_WRITABLE = [
        'latitude', 'longitude',
        'photo_url', 'aadhaar_front_url', 'aadhaar_back_url', 'pan_url', 'signature_url',
    ];

    public function handle(): void
    {
        $claims = $this->requireAuth();
        ensure_sequential_codes();
        $role   = strtolower(trim($claims['role'] ?? ''));
        if (!$role && !empty($claims['sub'])) {
            $p = Profile::firstRaw(' WHERE id = ?', [$claims['sub']]);
            if ($p) $role = strtolower(trim($p['role'] ?? ''));
        }
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        if (in_array($method, ['POST', 'PATCH', 'PUT', 'DELETE'], true)) {
            if ($role === 'customer') {
                json_error('Customers cannot modify customer records', 403);
            }
            if ($method === 'DELETE' && $role !== 'admin') {
                json_error('Only admins can delete customers', 403);
            }
            // Creating a customer with its linked login belongs to
            // customers.php; POST here is the admin-only safety net.
            if ($method === 'POST' && $role !== 'admin') {
                json_error('Only admins can create customers', 403);
            }
        }

        if ($method === 'PATCH' || $method === 'PUT') {
            $b = $this->body();

            // The same PAN rule customers.php applies. Only when the request
            // actually carries the field — a PATCH that does not mention `pan`
            // must not be judged on a value it never sent.
            if (array_key_exists('pan', $b)) {
                $b['pan'] = Customer::normalisePan($b['pan'] ?? null);
                // ResourceController::update() re-reads the body, so the
                // normalised value has to go back where it will read it.
                set_json_body($b);
            }

            // Same rule as customers.php: 10-digit numbers, primary not
            // repeated, two at most. Checked against the number being saved,
            // else the one already on the row.
            if (array_key_exists('alt_mobiles', $b)) {
                $primary = $b['mobile'] ?? null;
                if (!array_key_exists('mobile', $b)) {
                    $id = (string)($_GET['id'] ?? '');
                    if (str_starts_with($id, 'eq.')) $id = substr($id, 3);
                    $row = $id !== '' ? Customer::firstRaw(' WHERE id = ?', [$id]) : null;
                    $primary = $row['mobile'] ?? null;
                }
                $b['alt_mobiles'] = CustomerController::phoneList($b['alt_mobiles'], $primary);
                set_json_body($b);
            }

            if ($role === 'agent') {
                $refused = array_values(array_diff(array_keys($b), self::AGENT_WRITABLE));
                if ($refused) {
                    json_error(
                        'Agents can only update a customer\'s location and KYC documents. Refused: '
                        . implode(', ', $refused),
                        403
                    );
                }
            }

            if (array_key_exists('assigned_agent', $b)) {
                [$where, $binds] = QueryParser::where(Customer::columns());
                if ($where !== '') {
                    $agentId = $b['assigned_agent'] ?: null;
                    $agentName = null;
                    if ($agentId) {
                        $prof = Profile::findPublic($agentId);
                        $agentName = $prof['full_name'] ?? null;
                    }
                    // Sync assigned_agent to all loans belonging to the customer
                    $customers = Customer::select($where, $binds);
                    foreach ($customers as $cust) {
                        if (!empty($cust['id'])) {
                            Loan::updateWhere(['assigned_agent' => $agentId, 'agent_name' => $agentName], ' WHERE customer_id = ?', [$cust['id']]);
                        }
                    }
                }
            }
        }

        // Who may read which customers. This file's docblock said "any
        // authenticated user (frontend scopes rows per role)" and meant it
        // literally: a signed-in customer could pull the whole borrower
        // directory — every name, mobile number, address, Aadhaar and PAN in
        // the business. The screens never render that, which is why it went
        // unnoticed, but a request does not have to go through a screen.
        if ($method === 'GET') {
            if ($role === 'customer') {
                // Their own record, and nothing else. A customer login is
                // pinned to one customer row; anything else on this table is
                // somebody else's KYC.
                $own = $claims['customer_id'] ?? null;
                if (!$own && !empty($claims['sub'])) {
                    $p = Profile::firstRaw(' WHERE id = ?', [$claims['sub']]);
                    $own = $p['customer_id'] ?? null;
                }
                // No linked customer means no rows, not every row.
                QueryParser::addScope('`id` = ?', [$own ?? '']);
            } else {
                AgentScope::apply($this->model::table(), $role, $claims['sub'] ?? null);
            }
        }

        // Reads and deletes are handled generically by ResourceController:
        // it filters delflag = 0 for every table that has the column, and
        // turns DELETE into a flag update. Keeping a second copy of that rule
        // here is how the two drift apart.
        // The profile modal replaces one document at a time through this
        // route, so a photo can change here without going near the edit form.
        // The previous value has to be read before the write lands.
        if ($method !== 'GET' && $method !== 'DELETE') {
            $this->photoBefore = $this->currentPhotos();
        }

        parent::handle();
    }

    /** id => photo_url for the customers this write targets, read beforehand. */
    private array $photoBefore = [];

    /**
     * What the targeted customers' photos are right now.
     *
     * Scoped to the `id=eq.…` the update carries — which is how every write
     * from the app targets a row — rather than reading the whole table. Each
     * photo is a base64 image in a LONGTEXT column, so "just snapshot
     * everything" would pull megabytes on every save.
     */
    private function currentPhotos(): array
    {
        $id = $_GET['id'] ?? null;
        if (!is_string($id) || $id === '') return [];
        if (str_starts_with($id, 'eq.')) $id = substr($id, 3);
        if ($id === '') return [];

        $stmt = Database::pdo()->prepare('SELECT `id`, `photo_url` FROM `customers` WHERE `id` = ?');
        $stmt->execute([$id]);
        $out = [];
        foreach ($stmt->fetchAll(PDO::FETCH_ASSOC) as $row) {
            $out[(string)$row['id']] = $row['photo_url'];
        }
        return $out;
    }

    protected function afterWrite(string $method, array $rows): void
    {
        parent::afterWrite($method, $rows);
        if ($method === 'DELETE') return;

        foreach ($rows as $row) {
            $id = $row['id'] ?? null;
            if (!$id) continue;
            try {
                Customer::syncLoginAvatar((string)$id, $this->photoBefore[(string)$id] ?? null);
            } catch (\Throwable $e) {
                // Saving a customer must never fail because their login's
                // avatar could not be brought into step.
                error_log('syncLoginAvatar failed for customer ' . $id . ': ' . $e->getMessage());
            }
        }
    }

}
