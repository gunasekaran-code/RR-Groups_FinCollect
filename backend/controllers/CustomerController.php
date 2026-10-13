<?php
// Admin-only customer management: creates the customers business record and,
// optionally, a linked customer login (role=customer, linked via customer_id).

class CustomerController extends Controller
{
    public function handle(): void
    {
        $claims = $this->requireAuth();
        ensure_sequential_codes();
        $role   = strtolower(trim($claims['role'] ?? ''));
        if ($role === 'customer' || !$role) {
            json_error('Only admins or agents can manage customers', 403);
        }
        switch ($_SERVER['REQUEST_METHOD'] ?? '') {
            case 'POST':  $this->store();  break;
            case 'PATCH':
            case 'PUT':   $this->update(); break;
            default:      json_error('Method not allowed', 405);
        }
    }

    /**
     * A list of extra contact numbers, as digits separated by commas.
     *
     * Anything that is not a digit is dropped, blanks and duplicates go, and
     * the primary number is removed if it was repeated here — a list whose
     * first entry is the number already in `mobile` reads as two phones and
     * would be dialled twice. Each must be a 10-digit mobile number, and at
     * most two are kept — three numbers in all with the primary.
     */
    public static function phoneList($v, ?string $primary = null): ?string
    {
        if ($v === null) return null;
        $parts = is_array($v) ? $v : explode(',', (string)$v);
        $primaryDigits = preg_replace('/\D+/', '', (string)$primary);
        $out = [];
        foreach ($parts as $p) {
            $d = preg_replace('/\D+/', '', (string)$p);
            if ($d === '') continue;
            if (!preg_match('/^[6-9]\d{9}$/', $d)) {
                json_error('Each alternate number must be a valid 10-digit mobile number', 400);
            }
            if ($primaryDigits !== '' && $d === $primaryDigits) continue;
            if (in_array($d, $out, true)) continue;
            $out[] = $d;
            if (count($out) >= 2) break;
        }
        return $out ? implode(',', $out) : null;
    }

    private static function clean($v): ?string    {
        $v = is_string($v) ? trim($v) : '';
        return $v === '' ? null : $v;
    }

    /** Numeric coercion for coordinates (accepts JSON number or numeric string). */
    private static function num($v): ?float
    {
        if ($v === null || $v === '' || !is_numeric($v)) return null;
        return (float)$v;
    }

    public static function genCode(): string
    {
        $pdo = Database::pdo();
        $stmt = $pdo->query("SELECT customer_id FROM customers WHERE customer_id LIKE 'RRG-CUS-%'");
        $maxNum = 0;
        while ($row = $stmt->fetch(PDO::FETCH_ASSOC)) {
            if (preg_match('/RRG-CUS-(\d+)/i', $row['customer_id'], $m)) {
                $num = (int)$m[1];
                if ($num > $maxNum) $maxNum = $num;
            }
        }
        if ($maxNum === 0) {
            $maxNum = (int)$pdo->query("SELECT COUNT(*) FROM customers")->fetchColumn();
        }
        return sprintf('RRG-CUS-%04d', $maxNum + 1);
    }

    /**
     * Columns of the customers row this endpoint accepts, and how each is
     * coerced. The KYC images are ordinary text columns holding data URIs,
     * so they clean like any other string.
     */
    private const FIELDS = [
        'full_name'         => 'text',
        'mobile'            => 'text',
        'alt_mobiles'       => 'text',
        'address'           => 'text',
        'aadhaar'           => 'text',
        'pan'               => 'text',
        'occupation'        => 'text',
        'photo_url'         => 'text',
        'aadhaar_front_url' => 'text',
        'aadhaar_back_url'  => 'text',
        'pan_url'           => 'text',
        'signature_url'     => 'text',
        'assigned_agent'    => 'text',
        'latitude'          => 'num',
        'longitude'         => 'num',
    ];

    /**
     * Fields shared by the customers row.
     *
     * $partial narrows an update to the keys the caller actually sent. Without
     * it every PATCH writes the whole column list, so a request carrying only
     * a document image would blank the customer's address, PAN and map pin on
     * its way through — the create path still wants the full list, where a
     * missing key genuinely means NULL.
     */
    private function customerData(array $b, bool $partial = false, ?string $knownMobile = null): array
    {
        $out = [];
        foreach (self::FIELDS as $col => $kind) {
            if ($partial && !array_key_exists($col, $b)) continue;
            if ($col === 'alt_mobiles') {
                // The number being saved when the request carries one, else the
                // number already on the row. A PATCH that changes only the extra
                // numbers has no `mobile` in it, and that is precisely the
                // request where the primary could slip into the list.
                $primary = array_key_exists('mobile', $b) ? $b['mobile'] : $knownMobile;
                $out[$col] = self::phoneList($b[$col] ?? null, $primary);
                continue;
            }
            $out[$col] = $kind === 'num'
                ? self::num($b[$col] ?? null)
                : self::clean($b[$col] ?? null);
        }
        return $out;
    }

    private function store(): void
    {
        $b = $this->body();
        $data = $this->customerData($b);
        if (!$data['full_name']) json_error('Full name is required', 400);
        if (array_key_exists('pan', $b)) $data['pan'] = Customer::normalisePan($b['pan'] ?? null);

        // Naming an agent is optional — the column is nullable and an
        // unallocated customer is an ordinary thing to record. But an agent
        // creating one and leaving it blank would file it under nobody, and
        // AgentScope shows an agent only their own customers: the record would
        // vanish from the list the moment it refreshed, with nothing on screen
        // to explain where it went. Their own customer is the only sensible
        // reading of a blank field when an agent is the one filling it in.
        // An admin leaving it blank means what it says.
        $claims = $this->requireAuth();
        $role   = strtolower(trim($claims['role'] ?? ''));
        if ($role === 'agent' && empty($data['assigned_agent'])) {
            $data['assigned_agent'] = $claims['sub'] ?? null;
        }

        $email = strtolower((string)(self::clean($b['email'] ?? null) ?? ''));
        $password = (string)($b['password'] ?? '');
        $wantsLogin = $email !== '' || $password !== '';

        // Validate credentials up front so we never create a half-linked record.
        // The password is what creates the login; the email is optional, because
        // sign-in accepts a mobile number just as well as an email address.
        if ($wantsLogin) {
            $this->assertLoginCredentials($email, $password, $data['mobile'] ?? null, null);
        }

        $inputCode = self::clean($b['customer_id'] ?? null);
        $data['customer_id'] = ($inputCode && str_starts_with($inputCode, 'RRG-CUS-')) ? $inputCode : self::genCode();
        $rows = Customer::insertRows([$data]);
        $customer = $rows[0] ?? null;
        if (!$customer) json_error('Failed to create customer', 500);

        if ($wantsLogin) {
            $this->createLogin($customer['id'], $email, $password, $data, $customer['customer_id']);
        }
        json_out($customer, 201);
    }

    private function update(): void
    {
        $id = $_GET['id'] ?? '';
        if ($id === '') json_error('Missing customer id', 400);
        $existingCustomer = Customer::select(' WHERE id = ?', [$id], '', ' LIMIT 1')[0] ?? null;
        if (!$existingCustomer) json_error('Customer not found', 404);

        $b = $this->body();
        $data = $this->customerData($b, true, $existingCustomer['mobile'] ?? null);
        if (array_key_exists('pan', $b)) $data['pan'] = Customer::normalisePan($b['pan'] ?? null);
        if (array_key_exists('full_name', $b) && !($data['full_name'] ?? null)) {
            json_error('Full name cannot be empty', 400);
        }
        if ($data) Customer::updateWhere($data, ' WHERE id = ?', [$id]);

        // Keep loans in sync with the customer's assigned agent.
        if (array_key_exists('assigned_agent', $b)) {
            $agentId = $data['assigned_agent'];
            $agentName = null;
            if ($agentId) {
                $prof = Profile::findPublic($agentId);
                $agentName = $prof['full_name'] ?? null;
            }
            Loan::updateWhere(['assigned_agent' => $agentId, 'agent_name' => $agentName], ' WHERE customer_id = ?', [$id]);
        }

        // Optional login handling.
        $email = strtolower((string)(self::clean($b['email'] ?? null) ?? ''));
        $password = (string)($b['password'] ?? '');
        $login = Profile::findByCustomerId($id);

        if ($login) {
            $set = [];
            if ($email !== '') {
                if (!filter_var($email, FILTER_VALIDATE_EMAIL)) json_error('A valid email is required', 400);
                if (Profile::emailTaken($email, $login['id'])) json_error('That email is already registered', 409);
                $set['email'] = $email;
            }
            if ($password !== '') {
                if (strlen($password) < 6) json_error('Password must be at least 6 characters', 400);
                $set['password_hash'] = password_hash($password, PASSWORD_BCRYPT);
            }
            if (array_key_exists('full_name', $b)) $set['full_name'] = $data['full_name'];
            if (array_key_exists('mobile', $b))    $set['mobile'] = $data['mobile'];
            if ($set) Profile::updateWhere($set, ' WHERE id = ?', [$login['id']]);
        } elseif ($email !== '' || $password !== '') {
            // A partial update may carry no name or mobile at all, so the new
            // login falls back to what the customer record already holds.
            $identity = $data + $existingCustomer;
            $this->assertLoginCredentials($email, $password, $identity['mobile'] ?? null, null);
            $this->createLogin($id, $email, $password, $identity, $existingCustomer['customer_id'] ?? null);
        }

        // The photo may have just changed, and the customer's own panel reads
        // it off their login rather than off this row. `$existingCustomer` was
        // read before the write, so it still holds what the photo was.
        try {
            Customer::syncLoginAvatar($id, $existingCustomer['photo_url'] ?? null);
        } catch (\Throwable $e) {
            // Saving a customer must not fail because their login's picture
            // could not be brought into step. The rest.php route already
            // treated it this way; this one did not.
            error_log('syncLoginAvatar failed for customer ' . $id . ': ' . $e->getMessage());
        }

        $customer = Customer::select(' WHERE id = ?', [$id])[0] ?? null;
        json_out($customer);
    }

    /**
     * Credentials for a customer portal login.
     *
     * Sign-in resolves either an email or a mobile number, so an email is
     * optional — but then the mobile becomes the only way in, and it has to be
     * present and unambiguous. Two logins sharing a mobile would make sign-in
     * pick one of them arbitrarily.
     */
    private function assertLoginCredentials(string $email, string $password, ?string $mobile, ?string $exceptProfileId): void
    {
        if (strlen($password) < 6) {
            json_error('Password must be at least 6 characters', 400);
        }

        if ($email !== '') {
            if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
                json_error('Enter a valid email address, or leave it blank to sign in with the mobile number', 400);
            }
            if (Profile::emailTaken($email, $exceptProfileId)) {
                json_error('That email is already registered', 409);
            }
            return;
        }

        $digits = preg_replace('/\D+/', '', (string)$mobile);
        if (strlen($digits) < 10) {
            json_error('Without an email, a 10-digit mobile number is required to sign in', 400);
        }
        if (Profile::mobileTaken($digits, $exceptProfileId)) {
            json_error('That mobile number already has a login. Use a different number or set an email.', 409);
        }
    }

    private function createLogin(string $customerId, ?string $email, string $password, array $data, ?string $userCode = null): void
    {
        Profile::insertRows([[
            // NULL, not '': the column is UNIQUE, and MySQL allows many NULLs
            // but only one ''. Empty strings would collide on the second
            // mobile-only login.
            'email'         => ($email !== null && $email !== '') ? $email : null,
            'password_hash' => password_hash($password, PASSWORD_BCRYPT),
            'full_name'     => $data['full_name'] ?? null,
            'mobile'        => $data['mobile'] ?? null,
            'role'          => 'customer',
            'user_code'     => $userCode,
            'customer_id'   => $customerId,
            'avatar_url'    => $data['photo_url'] ?? null,
            'status'        => 'active',
        ]]);
    }
}
