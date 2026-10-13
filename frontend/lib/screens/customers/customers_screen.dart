import 'dart:convert';
import '../../models/customer.dart';
import '../../theme/app_theme.dart';
import '../../routes/app_routes.dart';
import '../../theme/glass_toast.dart';
import '../../widgets/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../widgets/page_header.dart';
import '../../theme/confirm_dialog.dart';
import '../../services/photo_service.dart';
import '../../widgets/app_upload.dart';
import '../../services/location_service.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/customer_api_service.dart';
import '../../services/session_service.dart';
import '../../models/user_role.dart';
import '../agent/agent_page.dart' show StatCard;
import 'customer_documents_download.dart';
import '../../widgets/responsive_stat_grid.dart';
import '../../widgets/phone_numbers_field.dart';

// ---------------------------------------------------------
// Shared helpers for decoding & rendering stored photos.
// Photos are stored as base64 data URIs (e.g.
// "data:image/jpeg;base64,...."), but this also gracefully
// handles a plain https URL if the backend ever returns one.
// ---------------------------------------------------------

Uint8List? decodePhotoBytes(String? data) {
  if (data == null || data.isEmpty) return null;
  if (data.startsWith('http://') || data.startsWith('https://')) return null;
  try {
    final base64Part = data.contains(',') ? data.split(',').last : data;
    return base64Decode(base64Part);
  } catch (_) {
    return null;
  }
}

class DocumentImage extends StatelessWidget {
  final String? data;
  final BoxFit fit;
  const DocumentImage({super.key, required this.data, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final url = data;
    if (url == null || url.isEmpty) {
      return const SizedBox.shrink();
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(url, fit: fit);
    }
    final bytes = decodePhotoBytes(url);
    if (bytes == null) return const SizedBox.shrink();
    return Image.memory(bytes, fit: fit);
  }
}

// Full-screen tap-to-zoom viewer for a single document/photo.
class FullScreenImageViewer extends StatelessWidget {
  final String data;
  final String title;
  const FullScreenImageViewer(
      {super.key, required this.data, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title),
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: DocumentImage(data: data, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

void openImageViewer(BuildContext context, String? data, String title) {
  if (data == null || data.isEmpty) return;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => FullScreenImageViewer(data: data, title: title),
      fullscreenDialog: true,
    ),
  );
}

class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  final _api = CustomerApiService();

  String _query = '';
  String _statusFilter = 'All Status';

  bool _loading = true;
  String? _error;
  List<Customer> _customers = [];
  List<AgentOption> _agents = [];

  bool get _isAgent =>
      SessionService.instance.currentUser?.role == UserRole.agent;

  int get _totalCustomers => _customers.length;
  int get _activeCustomers =>
      _customers.where((c) => _statusLabel(c.loanStatus) == 'Active').length;
  int get _overdueCustomers =>
      _customers.where((c) => _statusLabel(c.loanStatus) == 'Overdue').length;
  int get _inactiveCustomers =>
      _customers.where((c) => _statusLabel(c.loanStatus) == 'Inactive').length;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
    _loadAgents();
  }

  Future<void> _loadCustomers() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final customers = await _api.fetchAll();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      ToastService.show(
        title: 'Failed to Load Customers',
        message: _error!,
        type: ToastType.error,
      );
    }
  }

  Future<void> _loadAgents() async {
    try {
      final agents = await _api.fetchAgents();
      if (!mounted) return;
      setState(() => _agents = agents);
    } catch (e) {
      // debugPrint('Failed to load agents: $e');
    }
  }

  String _statusLabel(String loanStatus) {
    switch (loanStatus) {
      case 'active':
        return 'Active';
      case 'overdue':
        return 'Overdue';
      case 'closed':
        return 'Inactive';
      default:
        return 'Active';
    }
  }

  /// Customer details open as their own page inside the app shell: a back
  /// arrow in place of the drawer, with the bottom navbar still available.
  void _viewCustomer(Customer c) {
    final details = _api.fetchById(c.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppShell(
          currentRoute: AppRoutes.customers,
          title: 'Customer Details',
          showBackButton: true,
          body: Container(
            color: AppColors.kSurface,
            child: SingleChildScrollView(
              child: _CustomerViewSheet(
                customer: c,
                details: details,
                api: _api,
                agents: _agents,
                onPhotoChanged: () {
                  _CustomerAvatar._cache.remove(c.id);
                  _loadCustomers();
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteCustomer(Customer c) async {
    final confirmed = await AppConfirmDialog.show(
      context: context,
      title: 'Delete Customer',
      message:
          'Are you sure you want to delete ${c.fullName}? This action cannot be undone.',
      confirmLabel: 'Delete',
      confirmButtonColor: AppColors.kDanger,
    );
    if (confirmed != true || !mounted) return;

    try {
      await _api.delete(c.id);
      if (!mounted) return;
      await _loadCustomers();
      if (!mounted) return;
      ToastService.show(
        title: 'Customer Deleted',
        message: '${c.fullName} has been removed.',
        type: ToastType.success,
      );
    } catch (e) {
      ToastService.show(
        title: 'Delete Failed',
        message: e.toString(),
        type: ToastType.error,
      );
    }
  }

  /// Opens the edit form on the customer's full record. The list row has no
  /// KYC images (the list endpoint leaves them out), and the form writes back
  /// every image field it holds — opened on the list row, a save would blank
  /// the customer's photo and documents. So the form only opens once the
  /// full record has arrived.
  bool _openingEdit = false;
  Future<void> _editCustomer(Customer c) async {
    if (_openingEdit) return;
    _openingEdit = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    Customer? full;
    String? error;
    try {
      full = await _api.fetchById(c.id);
    } catch (e) {
      error = e.toString();
    }
    _openingEdit = false;
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    if (full == null) {
      ToastService.show(
        title: 'Failed to Load Customer',
        message: error ?? 'Customer not found',
        type: ToastType.error,
      );
      return;
    }
    _showCustomerFormModal(existingCustomer: full);
  }

  /// The add/edit form opens as its own page inside the app shell, like the
  /// details page: back arrow instead of the drawer, bottom navbar kept.
  void _showCustomerFormModal({Customer? existingCustomer}) {
    final isEditing = existingCustomer != null;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (pageContext) => AppShell(
          currentRoute: AppRoutes.customers,
          title: isEditing ? 'Edit Customer' : 'Add Customer',
          showBackButton: true,
          body: Container(
            color: AppColors.kSurface,
            child: SingleChildScrollView(
              child: _CustomerForm(
                initialData: existingCustomer,
                agents: _agents,
                onSave: (updated, email, password) async {
                  try {
                    if (isEditing) {
                      // Its photo may have changed; refetch on reload.
                      _CustomerAvatar._cache.remove(existingCustomer.id);
                      await _api.update(
                        existingCustomer.id,
                        updated,
                        email: email,
                        password: password,
                      );
                    } else {
                      await _api.create(updated,
                          email: email, password: password);
                    }
                    if (!mounted) return;
                    await _loadCustomers();
                    if (!mounted || !pageContext.mounted) return;
                    Navigator.pop(pageContext);
                    ToastService.show(
                      title: isEditing ? 'Customer Updated' : 'Customer Added',
                      message: isEditing
                          ? "${updated.fullName}'s details have been updated."
                          : '${updated.fullName} has been added successfully.',
                      type: ToastType.success,
                    );
                  } catch (e) {
                    ToastService.show(
                      title: 'Save Failed',
                      message: e.toString(),
                      type: ToastType.error,
                    );
                  }
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatsRow(bool isNarrow) {
    final cards = <Widget>[
      StatCard(
        icon: Icons.groups_outlined,
        iconColor: AppColors.kInfo,
        iconBg: const Color(0xFFF0F5FF),
        value: '$_totalCustomers',
        label: 'Total Customers',
      ),
      StatCard(
        icon: Icons.check_circle_outline,
        iconColor: AppColors.kSuccess,
        iconBg: const Color(0xFFF0FDF4),
        value: '$_activeCustomers',
        label: 'Active',
      ),
      StatCard(
        icon: Icons.warning_amber_outlined,
        iconColor: AppColors.kDanger,
        iconBg: const Color(0xFFFEF2F2),
        value: '$_overdueCustomers',
        label: 'Overdue',
      ),
      StatCard(
        icon: Icons.person_off_outlined,
        iconColor: AppColors.kTextMuted,
        iconBg: const Color(0xFFF3F4F6),
        value: '$_inactiveCustomers',
        label: 'Inactive',
      ),
    ];

    return ResponsiveStatGrid(
      children: cards,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isNarrow = MediaQuery.of(context).size.width < 700;
    final filtered = _customers.where((c) {
      final matchesName =
          c.fullName.toLowerCase().contains(_query.toLowerCase());
      final matchesStatus = _statusFilter == 'All Status' ||
          _statusLabel(c.loanStatus) == _statusFilter;
      return matchesName && matchesStatus;
    }).toList();

    return AppShell(
      currentRoute: AppRoutes.customers,
      title: 'Customers',
      body: Container(
        color: theme.scaffoldBackgroundColor,
        child: RefreshIndicator(
          onRefresh: _loadCustomers,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const PageHeader(
                title: 'Customers',
                subtitle: 'Manage customer profiles and loan accounts',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    onPressed: () => _showCustomerFormModal(),
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Add Customer'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _buildStatsRow(isNarrow),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  border:
                      Border.all(color: scheme.outline.withValues(alpha: 0.2)),
                ),
                child: Column(
                  children: [
                    TextField(
                      onChanged: (v) => setState(() => _query = v),
                      decoration: const InputDecoration(
                        hintText: 'Search by name...',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: scheme.outline.withValues(alpha: 0.2)),
                        color: scheme.surface,
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _statusFilter,
                          icon: const Icon(Icons.unfold_more,
                              size: 20, color: AppColors.kTextMuted),
                          items: ['All Status', 'Active', 'Overdue', 'Inactive']
                              .map((s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(s,
                                        style: const TextStyle(
                                            color: AppColors.kTextDark)),
                                  ))
                              .toList(),
                          onChanged: (val) {
                            if (val != null) {
                              setState(() => _statusFilter = val);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48),
                  child: Center(
                    child: Column(
                      children: [
                        Text(_error!,
                            style: const TextStyle(color: AppColors.kDanger)),
                        const SizedBox(height: 12),
                        OutlinedButton(
                            onPressed: _loadCustomers,
                            child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              else if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: Text('No customers found')),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 16),
                  itemBuilder: (context, index) {
                    final c = filtered[index];
                    return _CustomerCard(
                      customer: c,
                      statusLabel: _statusLabel(c.loanStatus),
                      agents: _agents,
                      onView: () => _viewCustomer(c),
                      onEdit: () => _editCustomer(c),
                      onDelete: _isAgent ? null : () => _deleteCustomer(c),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// CUSTOMER VIEW SHEET
// ---------------------------------------------------------

class _CustomerViewSheet extends StatefulWidget {
  /// The row from the list, shown straight away. It lacks the KYC images
  /// (the list endpoint leaves them out), which [details] fills in.
  final Customer customer;

  /// The full record for this customer, fetched when the sheet opens.
  final Future<Customer> details;
  final List<AgentOption> agents;

  /// Writes a replaced document back to the customer record.
  final CustomerApiService api;

  /// Called after the profile photo is replaced, so the list's avatar can
  /// refresh.
  final VoidCallback? onPhotoChanged;
  const _CustomerViewSheet({
    required this.customer,
    required this.details,
    required this.api,
    this.agents = const [],
    this.onPhotoChanged,
  });

  @override
  State<_CustomerViewSheet> createState() => _CustomerViewSheetState();
}

class _CustomerViewSheetState extends State<_CustomerViewSheet> {
  late Customer customer = widget.customer;
  bool _loading = true;
  /// Label of the document being saved, so only its card shows a spinner.
  String? _savingDoc;

  /// Label of the document being uploaded.
  String? _updatingDoc;

  /// rest.php lets admins and agents write the KYC document columns;
  /// customers cannot write customer records at all.
  bool get _canUpdateDocs {
    final role = SessionService.instance.currentUser?.role;
    return role == UserRole.admin ||
        role == UserRole.owner ||
        role == UserRole.agent;
  }
  String? _error;

  List<AgentOption> get agents => widget.agents;

  @override
  void initState() {
    super.initState();
    widget.details.then((full) {
      if (!mounted) return;
      setState(() {
        customer = full;
        _loading = false;
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    });
  }

  /// The customer's assigned-agent id resolved to a display name. The
  /// customers list endpoint only returns the raw `assigned_agent` uuid, so
  /// this looks the name up from the agents already loaded for the assign
  /// form, falling back to whatever the API did provide.
  String? get _assignedAgentLabel {
    final id = customer.assignedAgent;
    if (id != null && id.isNotEmpty) {
      for (final a in agents) {
        if (a.id == id) return a.fullName;
      }
    }
    return customer.assignedAgentName ?? customer.assignedAgent;
  }

  /// Saves one document as a JPEG: into the gallery on a phone, as a
  /// browser download on web.
  Future<void> _downloadDocument(_DocEntry doc) async {
    if (_savingDoc != null) return;
    setState(() => _savingDoc = doc.label);
    try {
      final saved = await downloadDocumentAsJpeg(
        customerCode: customer.customerId,
        label: doc.label,
        data: doc.data,
      );
      ToastService.show(
        title: saved == null ? 'Download Failed' : '${doc.label} Downloaded',
        message: switch (saved) {
          null => 'This image could not be read.',
          (DocumentSavedTo.gallery, _) =>
            'Saved as JPEG to the "$customerDocumentsAlbum" album in your '
                'gallery.',
          (DocumentSavedTo.browser, _) =>
            'Saved as JPEG to your Downloads folder.',
          (DocumentSavedTo.folder, final path) => 'Saved as JPEG to $path',
        },
        type: saved == null ? ToastType.error : ToastType.success,
      );
    } catch (e) {
      ToastService.show(
        title: 'Download Failed',
        message: e.toString().replaceFirst('Exception: ', ''),
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _savingDoc = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  customer.fullName,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: AppColors.kTextDark),
                ),
              ),
            ],
          ),
          if (_loading) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              'Could not load full details: $_error',
              style: const TextStyle(fontSize: 12, color: AppColors.kDanger),
            ),
          ],
          const SizedBox(height: 24),
          _buildViewField('Customer ID', customer.customerId),
          _buildViewField('Mobile Number', customer.mobile),
          if (customer.altMobiles.isNotEmpty)
            _buildViewField(
                'Alternate Numbers', customer.altMobiles.join(', ')),
          _buildViewField('Address', customer.address),
          _buildViewField('Aadhaar Number', customer.aadhaar),
          _buildViewField('PAN Number', customer.pan),
          _buildViewField('Occupation', customer.occupation),
          _buildViewField('Login Email', customer.email),
          _buildViewField('Assigned Agent', _assignedAgentLabel),
          _buildViewField('Loan Status', customer.loanStatus),
          const SizedBox(height: 8),
          _sectionLabel(Icons.image_outlined, 'Documents & Photos'),
          const SizedBox(height: 12),
          _buildDocumentsGrid(context),
        ],
      ),
    );
  }

  Widget _sectionLabel(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.kGoldDark),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.kGoldDark,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: AppColors.kBorder, height: 1)),
      ],
    );
  }

  List<_DocEntry> get _docs => [
        _DocEntry('Profile Photo', Icons.person_outline, customer.photoUrl,
            'photo_url'),
        _DocEntry('Aadhaar Front', Icons.badge_outlined,
            customer.aadhaarFrontUrl, 'aadhaar_front_url'),
        _DocEntry('Aadhaar Back', Icons.badge_outlined,
            customer.aadhaarBackUrl, 'aadhaar_back_url'),
        _DocEntry('PAN Card', Icons.credit_card_outlined, customer.panUrl,
            'pan_url'),
        _DocEntry('Signature', Icons.draw_outlined, customer.signatureUrl,
            'signature_url'),
      ];

  /// [customer] with [column] set to [dataUri].
  Customer _withDocument(String column, String dataUri) => switch (column) {
        'photo_url' => customer.copyWith(photoUrl: dataUri),
        'aadhaar_front_url' => customer.copyWith(aadhaarFrontUrl: dataUri),
        'aadhaar_back_url' => customer.copyWith(aadhaarBackUrl: dataUri),
        'pan_url' => customer.copyWith(panUrl: dataUri),
        'signature_url' => customer.copyWith(signatureUrl: dataUri),
        _ => customer,
      };

  /// Picks a new image (camera or gallery) and saves it to the backend in
  /// place of [doc]; the card shows the new image once the server accepts it.
  Future<void> _updateDocument(_DocEntry doc) async {
    if (_updatingDoc != null || _loading) return;
    final picked = await AppUpload.showImagePickerModal(
      context,
      title: doc.hasImage ? 'Update ${doc.label}' : 'Upload ${doc.label}',
    );
    if (picked == null || !mounted) return;

    setState(() => _updatingDoc = doc.label);
    try {
      final dataUri = await encodeDocumentForUpload(await picked.readAsBytes());
      await widget.api.updateDocument(customer.id, doc.column, dataUri);
      if (!mounted) return;
      setState(() => customer = _withDocument(doc.column, dataUri));
      if (doc.column == 'photo_url') widget.onPhotoChanged?.call();
      ToastService.show(
        title: '${doc.label} Updated',
        message: '${customer.fullName}\'s ${doc.label.toLowerCase()} has been '
            'saved.',
        type: ToastType.success,
      );
    } catch (e) {
      ToastService.show(
        title: 'Update Failed',
        message: e.toString(),
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _updatingDoc = null);
    }
  }

  Widget _buildDocumentsGrid(BuildContext context) {
    final docs = _docs;

    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 420;
      return GridView.count(
        crossAxisCount: isNarrow ? 2 : 5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
        children: docs
            .map((d) => _DocThumbCard(
                  entry: d,
                  loading: _loading,
                  onTap: d.hasImage
                      ? () => openImageViewer(context, d.data, d.label)
                      : null,
                  onDownload: d.hasImage && _savingDoc == null
                      ? () => _downloadDocument(d)
                      : null,
                  downloading: _savingDoc == d.label,
                  onUpdate: _canUpdateDocs && !_loading && _updatingDoc == null
                      ? () => _updateDocument(d)
                      : null,
                  updating: _updatingDoc == d.label,
                ))
            .toList(),
      );
    });
  }

  Widget _buildViewField(String label, String? value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.kBackground,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.kBorder),
            ),
            child: Text((value == null || value.trim().isEmpty) ? '-' : value,
                style:
                    const TextStyle(color: AppColors.kTextDark, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

class _DocEntry {
  final String label;
  final IconData icon;
  final String? data;

  /// The `customers` column this document is stored in.
  final String column;
  _DocEntry(this.label, this.icon, this.data, this.column);
  bool get hasImage => data != null && data!.isNotEmpty;
}

class _DocThumbCard extends StatelessWidget {
  final _DocEntry entry;
  final VoidCallback? onTap;

  /// Saves this image as a JPEG; null hides the button.
  final VoidCallback? onDownload;

  /// This card's image is being saved.
  final bool downloading;

  /// Picks a new image and uploads it in place of this one; null hides the
  /// button.
  final VoidCallback? onUpdate;

  /// This card's new image is being uploaded.
  final bool updating;

  /// The full record is still on its way, so "Not uploaded" would be a guess.
  final bool loading;
  const _DocThumbCard({
    required this.entry,
    this.onTap,
    this.onDownload,
    this.downloading = false,
    this.onUpdate,
    this.updating = false,
    this.loading = false,
  });

  static const _badgeDecoration = BoxDecoration(
    color: Colors.black54,
    shape: BoxShape.circle,
  );

  static const _spinner = SizedBox(
    width: 14,
    height: 14,
    child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white),
  );

  /// A small round icon button over the image. [onTap] null with [busy]
  /// false hides it.
  Widget _badgeButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    required bool busy,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: busy ? null : onTap,
            child: Ink(
              padding: const EdgeInsets.all(4),
              decoration: _badgeDecoration,
              child: busy
                  ? _spinner
                  : Icon(icon,
                      size: 14, color: Colors.white, semanticLabel: tooltip),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[
      if (updating || onUpdate != null)
        _badgeButton(
          icon: entry.hasImage
              ? Icons.add_photo_alternate_outlined
              : Icons.add_a_photo_outlined,
          tooltip: entry.hasImage ? 'Update image' : 'Upload image',
          onTap: onUpdate,
          busy: updating,
        ),
      if (entry.hasImage && (downloading || onDownload != null))
        _badgeButton(
          icon: Icons.download_rounded,
          tooltip: 'Download as JPEG',
          onTap: onDownload,
          busy: downloading,
        ),
      if (entry.hasImage)
        Container(
          padding: const EdgeInsets.all(4),
          decoration: _badgeDecoration,
          child: const Icon(Icons.zoom_in, size: 14, color: Colors.white),
        ),
    ];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.kBackground,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.kBorder),
          ),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(14)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (entry.hasImage)
                        DocumentImage(data: entry.data, fit: BoxFit.cover)
                      else
                        Container(
                          color: AppColors.kBorder.withOpacity(0.3),
                          child: Center(
                            child: loading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  )
                                : Icon(entry.icon,
                                    size: 26, color: AppColors.kTextMuted),
                          ),
                        ),
                      if (badges.isNotEmpty)
                        Positioned(
                          right: 4,
                          bottom: 4,
                          child: Row(children: badges),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 8),
                child: Column(
                  children: [
                    Text(
                      entry.label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.kTextDark),
                    ),
                    if (!entry.hasImage)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          loading ? 'Loading…' : 'Not uploaded',
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.kTextMuted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// CUSTOMER AVATAR
// The list endpoint sends `has_photo` instead of the picture, so the photo
// is fetched from photo.php, once per customer per session.
// ---------------------------------------------------------

class _CustomerAvatar extends StatefulWidget {
  final Customer customer;
  final String initials;
  const _CustomerAvatar({required this.customer, required this.initials});

  static final Map<String, Future<Uint8List?>> _cache = {};
  static final _api = CustomerApiService();

  @override
  State<_CustomerAvatar> createState() => _CustomerAvatarState();
}

class _CustomerAvatarState extends State<_CustomerAvatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _CustomerAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A reload hands every card a fresh Customer; re-resolve from the cache
    // (instant for unchanged photos) so an edited photo shows up. The old
    // picture stays on screen until the new one is ready.
    if (!identical(oldWidget.customer, widget.customer)) {
      if (oldWidget.customer.id != widget.customer.id ||
          !widget.customer.hasPhoto) {
        _bytes = null;
      }
      _load();
    }
  }

  void _load() {
    final c = widget.customer;
    final inline = decodePhotoBytes(c.photoUrl);
    if (inline != null) {
      _bytes = inline;
      return;
    }
    if (!c.hasPhoto || c.id.isEmpty) return;
    final id = c.id;
    final future = _CustomerAvatar._cache
        .putIfAbsent(id, () => _CustomerAvatar._api.fetchPhotoBytes(id));
    future.then((bytes) {
      if (bytes == null) _CustomerAvatar._cache.remove(id);
      if (!mounted || widget.customer.id != id) return;
      setState(() => _bytes = bytes);
    }).catchError((_) {
      _CustomerAvatar._cache.remove(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return CircleAvatar(
      radius: 24,
      backgroundColor: AppColors.kGold,
      backgroundImage: bytes != null ? MemoryImage(bytes) : null,
      child: bytes == null
          ? Text(
              widget.initials,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 18),
            )
          : null,
    );
  }
}

// ---------------------------------------------------------
// CUSTOMER CARD
// ---------------------------------------------------------

class _CustomerCard extends StatelessWidget {
  final Customer customer;
  final String statusLabel;
  final List<AgentOption> agents;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  const _CustomerCard({
    required this.customer,
    required this.statusLabel,
    this.agents = const [],
    required this.onView,
    required this.onEdit,
    this.onDelete,
  });

  /// See _CustomerViewSheet._assignedAgentLabel: the customers list endpoint
  /// only returns the raw `assigned_agent` uuid, so resolve it against the
  /// agents already loaded for the assign form.
  String? get _assignedAgentLabel {
    final id = customer.assignedAgent;
    if (id != null && id.isNotEmpty) {
      for (final a in agents) {
        if (a.id == id) return a.fullName;
      }
    }
    return customer.assignedAgentName ?? customer.assignedAgent;
  }

  String _getInitials(String name) {
    final parts = name.trim().split(' ');
    if (parts.length > 1 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return name.length >= 2
        ? name.substring(0, 2).toUpperCase()
        : name.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = statusLabel == 'Active';
    final badgeColor = isActive
        ? AppColors.kSuccess.withOpacity(0.1)
        : AppColors.kDanger.withOpacity(0.1);
    final badgeTextColor = isActive ? AppColors.kSuccess : AppColors.kDanger;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.kSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CustomerAvatar(
                customer: customer,
                initials: _getInitials(customer.fullName),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(customer.fullName,
                        style: const TextStyle(
                            color: AppColors.kTextDark,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(customer.customerId,
                        style: const TextStyle(
                            color: AppColors.kTextMuted, fontSize: 13)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: badgeColor, borderRadius: BorderRadius.circular(12)),
                child: Text(statusLabel,
                    style: TextStyle(
                        color: badgeTextColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                  child: _DetailItem(
                      icon: Icons.phone_outlined,
                      text: customer.mobile ?? '-')),
              Expanded(
                  child: _DetailItem(
                      icon: Icons.location_on_outlined,
                      text: customer.address ?? '-')),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _DetailItem(
                      icon: Icons.credit_card_outlined,
                      text: customer.aadhaar ?? '-')),
              Expanded(
                  child: _DetailItem(
                      icon: Icons.business_center_outlined,
                      text: _assignedAgentLabel ?? 'Unassigned')),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ActionButton(
                  icon: Icons.visibility_outlined,
                  label: 'View',
                  color: AppColors.kInfo,
                  onTap: onView),
              _ActionButton(
                  icon: Icons.edit_outlined,
                  label: 'Edit',
                  color: AppColors.kGoldDark,
                  onTap: onEdit),
              if (onDelete != null)
                _ActionButton(
                    icon: Icons.delete_outline,
                    label: 'Delete',
                    color: AppColors.kDanger,
                    onTap: onDelete!),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final IconData icon;
  final String text;
  const _DetailItem({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.kTextMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text,
              style: const TextStyle(color: AppColors.kTextDark, fontSize: 13),
              overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.icon,
      required this.label,
      this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final activeColor = color ?? AppColors.kTextDark;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: activeColor),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      color: activeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------
// CUSTOMER FORM (ADD & EDIT) — validated, stylish, responsive
// Portal login uses the customer's MOBILE NUMBER + PASSWORD.
// No email/Gmail field is required anywhere in this form.
// ---------------------------------------------------------

class _CustomerForm extends StatefulWidget {
  final Customer? initialData;
  final List<AgentOption> agents;
  final void Function(Customer updated, String? email, String password) onSave;

  const _CustomerForm({
    this.initialData,
    required this.agents,
    required this.onSave,
  });

  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  final _formKey = GlobalKey<FormState>();
  final _locationService = LocationService();
  final _photoService = PhotoService();

  late TextEditingController _nameCtrl;
  late PhoneNumbersController _phones;
  late TextEditingController _addressCtrl;
  late TextEditingController _aadhaarCtrl;
  late TextEditingController _panCtrl;
  late TextEditingController _occupationCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _passwordCtrl;
  late TextEditingController _latCtrl;
  late TextEditingController _lngCtrl;

  String? _assignedAgentId;

  // Photo / document state
  String? _profilePhoto;
  String? _aadhaarFrontPhoto;
  String? _aadhaarBackPhoto;
  String? _panPhoto;
  String? _signaturePhoto;

  bool _locationBusy = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    final d = widget.initialData;
    _nameCtrl = TextEditingController(text: d?.fullName ?? '');
    _phones = PhoneNumbersController(
        primary: d?.mobile, alternates: d?.altMobiles ?? const []);
    _addressCtrl = TextEditingController(text: d?.address ?? '');
    _aadhaarCtrl = TextEditingController(text: d?.aadhaar ?? '');
    _panCtrl = TextEditingController(text: d?.pan ?? '');
    _occupationCtrl = TextEditingController(text: d?.occupation ?? '');
    _emailCtrl = TextEditingController(text: d?.email ?? '');
    _passwordCtrl = TextEditingController();
    _latCtrl = TextEditingController(text: d?.latitude?.toString() ?? '');
    _lngCtrl = TextEditingController(text: d?.longitude?.toString() ?? '');
    _assignedAgentId = d?.assignedAgent;
    _profilePhoto = d?.photoUrl;
    _aadhaarFrontPhoto = d?.aadhaarFrontUrl;
    _aadhaarBackPhoto = d?.aadhaarBackUrl;
    _panPhoto = d?.panUrl;
    _signaturePhoto = d?.signatureUrl;
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _nameCtrl.dispose();
    _phones.dispose();
    _addressCtrl.dispose();
    _aadhaarCtrl.dispose();
    _panCtrl.dispose();
    _occupationCtrl.dispose();
    _passwordCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  Future<void> _pinFromAddress() async {
    if (_addressCtrl.text.trim().isEmpty) {
      ToastService.show(
        title: 'Address Required',
        message: 'Please enter an address first.',
        type: ToastType.error,
      );
      return;
    }
    setState(() => _locationBusy = true);
    try {
      final result = await _locationService.geocodeAddress(_addressCtrl.text);
      setState(() {
        _latCtrl.text = result.latitude.toStringAsFixed(7);
        _lngCtrl.text = result.longitude.toStringAsFixed(7);
      });
    } catch (e) {
      ToastService.show(
          title: 'Address Not Found',
          message: e.toString(),
          type: ToastType.error);
    } finally {
      if (mounted) setState(() => _locationBusy = false);
    }
  }

  Future<void> _useMyGps() async {
    setState(() => _locationBusy = true);
    try {
      final result = await _locationService.getCurrentPosition();
      setState(() {
        _latCtrl.text = result.latitude.toStringAsFixed(7);
        _lngCtrl.text = result.longitude.toStringAsFixed(7);
      });
    } catch (e) {
      ToastService.show(
          title: 'Location Failed',
          message: e.toString(),
          type: ToastType.error);
    } finally {
      if (mounted) setState(() => _locationBusy = false);
    }
  }

Future<void> _pickPhotoFor(_PhotoSlot slot) async {
    try {
      final XFile? picked = await AppUpload.showImagePickerModal(
        context,
        title: 'Update Photo',
      );
      if (picked == null) return;

      final bytes = await picked.readAsBytes();
      final base64Str = base64Encode(bytes);
      final mimeType = picked.mimeType ?? 'image/jpeg';
      final dataUri = 'data:$mimeType;base64,$base64Str';

      setState(() {
        switch (slot) {
          case _PhotoSlot.profile:
            _profilePhoto = dataUri;
            break;
          case _PhotoSlot.aadhaarFront:
            _aadhaarFrontPhoto = dataUri;
            break;
          case _PhotoSlot.aadhaarBack:
            _aadhaarBackPhoto = dataUri;
            break;
          case _PhotoSlot.pan:
            _panPhoto = dataUri;
            break;
          case _PhotoSlot.signature:
            _signaturePhoto = dataUri;
            break;
        }
      });
    } catch (e) {
      ToastService.show(
          title: 'Photo Upload Failed',
          message: e.toString(),
          type: ToastType.error);
    }
  }

  void _removePhoto(_PhotoSlot slot) {
    setState(() {
      switch (slot) {
        case _PhotoSlot.profile:
          _profilePhoto = null;
          break;
        case _PhotoSlot.aadhaarFront:
          _aadhaarFrontPhoto = null;
          break;
        case _PhotoSlot.aadhaarBack:
          _aadhaarBackPhoto = null;
          break;
        case _PhotoSlot.pan:
          _panPhoto = null;
          break;
        case _PhotoSlot.signature:
          _signaturePhoto = null;
          break;
      }
    });
  }

  // ---- Validators ----

  String? _validateName(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Full name is required';
    return null;
  }

  String? _validateAddress(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Address is required';
    if (value.length < 5) return 'Address must be at least 5 characters';
    return null;
  }

  String? _validateAadhaar(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional
    if (!RegExp(r'^\d{12}$').hasMatch(value)) {
      return 'Aadhaar number must be 12 digits';
    }
    return null;
  }

  String? _validatePan(String? v) {
    final value = v?.trim().toUpperCase() ?? '';
    if (value.isEmpty) return null; // optional
    if (!RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]{1}$').hasMatch(value)) {
      return 'Enter a valid PAN (e.g. ABCDE1234F)';
    }
    return null;
  }

  String? _validateOccupation(String? v) {
    final value = v?.trim() ?? '';
    if (value.isNotEmpty && value.length < 2) {
      return 'Occupation must be at least 2 characters';
    }
    return null;
  }

  String? _validateLatitude(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional
    final parsed = double.tryParse(value);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < -90 || parsed > 90) return 'Latitude must be between -90 and 90';
    return null;
  }

  String? _validateLongitude(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional
    final parsed = double.tryParse(value);
    if (parsed == null) return 'Enter a valid number';
    if (parsed < -180 || parsed > 180) {
      return 'Longitude must be between -180 and 180';
    }
    return null;
  }

  String? _validateEmail(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return null; // optional
    final ok = RegExp(r'^[\w.+-]+@[\w-]+\.[a-zA-Z]{2,}$').hasMatch(value);
    if (!ok) return 'Enter a valid email address';
    return null;
  }

  String? _validatePassword(String? v) {
    final value = v ?? '';
    if (value.isEmpty) return null; // optional unless portal login is configured
    if (value.length < 6) return 'Password must be at least 6 characters';
    return null;
  }

  void _handleSave() {
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      ToastService.show(
        title: 'Validation Error',
        message: 'Please fix the errors in the form.',
        type: ToastType.error,
      );
      return;
    }
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;

    final updated = Customer(
      id: widget.initialData?.id ?? '',
      customerId: widget.initialData?.customerId ?? '',
      fullName: _nameCtrl.text.trim(),
      mobile: _phones.primaryNumber,
      altMobiles: _phones.alternateNumbers,
      address: _addressCtrl.text.trim(),
      aadhaar: _aadhaarCtrl.text.trim(),
      pan: _panCtrl.text.trim().toUpperCase(),
      occupation: _occupationCtrl.text.trim(),
      photoUrl: _profilePhoto,
      aadhaarFrontUrl: _aadhaarFrontPhoto,
      aadhaarBackUrl: _aadhaarBackPhoto,
      panUrl: _panPhoto,
      signatureUrl: _signaturePhoto,
      assignedAgent: _assignedAgentId,
      latitude: double.tryParse(_latCtrl.text.trim()),
      longitude: double.tryParse(_lngCtrl.text.trim()),
      loanStatus: widget.initialData?.loanStatus ?? 'none',
    );

    widget.onSave(updated, email.isEmpty ? null : email, password);
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initialData != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 420;

        return Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: isNarrow ? 16 : 24, vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---- Header ----
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [AppColors.kGold, AppColors.kGoldDark],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.kGoldDark.withOpacity(0.35),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Icon(
                            isEditing
                                ? Icons.person_outline
                                : Icons.person_add_alt_1_outlined,
                            color: Colors.white,
                            size: 20,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isEditing ? 'Edit Customer' : 'Add New Customer',
                              style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.kTextDark),
                            ),
                            Text(
                              isEditing
                                  ? 'Update customer details'
                                  : 'Enter customer details below',
                              style: const TextStyle(
                                  fontSize: 12, color: AppColors.kTextMuted),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                _sectionLabel(Icons.badge_outlined, 'Personal Details'),
                const SizedBox(height: 12),

                _buildInputField(
                  'Full Name',
                  'Enter full name',
                  _nameCtrl,
                  validator: _validateName,
                  prefixIcon: Icons.person_outline,
                  textCapitalization: TextCapitalization.words,
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: PhoneNumbersField(
                    controller: _phones,
                    label: 'Mobile Number',
                  ),
                ),
                _buildInputField(
                  'Address',
                  'Enter full address',
                  _addressCtrl,
                  validator: _validateAddress,
                  prefixIcon: Icons.location_on_outlined,
                  maxLines: 3,
                ),

                isNarrow
                    ? Column(
                        children: [
                          _buildInputField(
                            'Aadhaar Number',
                            '12-digit Aadhaar number',
                            _aadhaarCtrl,
                            validator: _validateAadhaar,
                            prefixIcon: Icons.credit_card_outlined,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(12),
                            ],
                          ),
                          _buildInputField(
                            'PAN Number',
                            'e.g. ABCDE1234F',
                            _panCtrl,
                            validator: _validatePan,
                            prefixIcon: Icons.badge_outlined,
                            textCapitalization: TextCapitalization.characters,
                            inputFormatters: [
                              LengthLimitingTextInputFormatter(10)
                            ],
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildInputField(
                              'Aadhaar Number',
                              '12-digit Aadhaar number',
                              _aadhaarCtrl,
                              validator: _validateAadhaar,
                              prefixIcon: Icons.credit_card_outlined,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(12),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildInputField(
                              'PAN Number',
                              'e.g. ABCDE1234F',
                              _panCtrl,
                              validator: _validatePan,
                              prefixIcon: Icons.badge_outlined,
                              textCapitalization: TextCapitalization.characters,
                              inputFormatters: [
                                LengthLimitingTextInputFormatter(10)
                              ],
                            ),
                          ),
                        ],
                      ),

                _buildInputField(
                  'Occupation',
                  'Enter occupation',
                  _occupationCtrl,
                  validator: _validateOccupation,
                  prefixIcon: Icons.work_outline,
                  textCapitalization: TextCapitalization.sentences,
                ),

                const SizedBox(height: 4),
                _sectionLabel(
                    Icons.groups_outlined, 'Assignment & Location'),
                const SizedBox(height: 12),

                // ASSIGNED AGENT
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Assigned Agent',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppColors.kTextMuted)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: AppColors.kBorder),
                          color: AppColors.kBackground,
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String?>(
                            isExpanded: true,
                            value: _assignedAgentId,
                            hint: const Text('Unassigned',
                                style: TextStyle(color: AppColors.kTextMuted)),
                            icon: const Icon(Icons.unfold_more,
                                size: 20, color: AppColors.kTextMuted),
                            items: [
                              const DropdownMenuItem<String?>(
                                  value: null, child: Text('Unassigned')),
                              ...widget.agents
                                  .map((a) => DropdownMenuItem<String?>(
                                        value: a.id,
                                        child: Text(a.fullName,
                                            style: const TextStyle(
                                                color: AppColors.kTextDark)),
                                      )),
                            ],
                            onChanged: (val) =>
                                setState(() => _assignedAgentId = val),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // MAP LOCATION
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 24),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.kBackground,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.map_outlined,
                              size: 18, color: AppColors.kGoldDark),
                          SizedBox(width: 8),
                          Text('Map Location',
                              style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.kTextDark)),
                        ],
                      ),
                      const Text(
                          "Pin the customer's location for field visits",
                          style: TextStyle(
                              fontSize: 12, color: AppColors.kTextMuted)),
                      const SizedBox(height: 12),
                      isNarrow
                          ? Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed:
                                        _locationBusy ? null : _pinFromAddress,
                                    icon: const Icon(Icons.location_searching,
                                        size: 16),
                                    label: const Text('Pin from Address'),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: _locationBusy ? null : _useMyGps,
                                    icon: const Icon(Icons.gps_fixed, size: 16),
                                    label: const Text('Use My GPS'),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed:
                                        _locationBusy ? null : _pinFromAddress,
                                    icon: const Icon(Icons.location_searching,
                                        size: 16),
                                    label: const Text('Pin from Address'),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: _locationBusy ? null : _useMyGps,
                                    icon: const Icon(Icons.gps_fixed, size: 16),
                                    label: const Text('Use My GPS'),
                                  ),
                                ),
                              ],
                            ),
                      if (_locationBusy)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                      const SizedBox(height: 16),
                      isNarrow
                          ? Column(
                              children: [
                                _buildInputField(
                                    'Latitude',
                                    'Enter latitude',
                                    _latCtrl,
                                    validator: _validateLatitude,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true, signed: true)),
                                _buildInputField(
                                    'Longitude',
                                    'Enter longitude',
                                    _lngCtrl,
                                    validator: _validateLongitude,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                            decimal: true, signed: true)),
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                    child: _buildInputField(
                                        'Latitude',
                                        'Enter latitude',
                                        _latCtrl,
                                        validator: _validateLatitude,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(
                                            decimal: true, signed: true))),
                                const SizedBox(width: 12),
                                Expanded(
                                    child: _buildInputField(
                                        'Longitude',
                                        'Enter longitude',
                                        _lngCtrl,
                                        validator: _validateLongitude,
                                        keyboardType: const TextInputType
                                            .numberWithOptions(
                                            decimal: true, signed: true))),
                              ],
                            ),
                      const Text(
                        "This helps agents navigate to the customer's location during field visits.",
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColors.kTextMuted,
                            height: 1.4),
                      ),
                    ],
                  ),
                ),

                _sectionLabel(Icons.lock_outline, 'Portal Login'),
                const SizedBox(height: 12),

                // PORTAL LOGIN — mobile number + password (no email required)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 24),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.kBackground,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.kBorder),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: AppColors.kGoldDark.withOpacity(0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.phonelink_lock_outlined,
                                size: 16, color: AppColors.kGoldDark),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Customer will use their mobile number and this password to log in to the portal.',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.kTextMuted,
                                  height: 1.4),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _buildInputField(
                        'Email (Optional)',
                        'customer@example.com',
                        _emailCtrl,
                        validator: _validateEmail,
                        prefixIcon: Icons.email_outlined,
                        keyboardType: TextInputType.emailAddress,
                      ),
                      _buildInputField(
                        'Password',
                        'Leave blank to keep unchanged',
                        _passwordCtrl,
                        validator: _validatePassword,
                        prefixIcon: Icons.key_outlined,
                        obscureText: _obscurePassword,
                        suffixIcon: IconButton(
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                            color: AppColors.kTextMuted,
                          ),
                          onPressed: () => setState(
                              () => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      const Row(
                        children: [
                          Icon(Icons.info_outline,
                              size: 14, color: AppColors.kTextMuted),
                          SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              "Password is optional. Leave blank if you don't want to set up portal access.",
                              style: TextStyle(
                                  fontSize: 11, color: AppColors.kTextMuted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                _sectionLabel(Icons.image_outlined, 'Documents & Photos'),
                const SizedBox(height: 12),

                // DOCUMENTS & PHOTOS
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GridView.count(
                    crossAxisCount: isNarrow ? 2 : 5,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                    children: [
                      _PhotoUploadCard(
                        label: 'Profile Photo',
                        icon: Icons.person_outline,
                        data: _profilePhoto,
                        onPick: () => _pickPhotoFor(_PhotoSlot.profile),
                        onRemove: () => _removePhoto(_PhotoSlot.profile),
                        onPreview: () => openImageViewer(
                            context, _profilePhoto, 'Profile Photo'),
                      ),
                      _PhotoUploadCard(
                        label: 'Aadhaar Front',
                        icon: Icons.badge_outlined,
                        data: _aadhaarFrontPhoto,
                        onPick: () => _pickPhotoFor(_PhotoSlot.aadhaarFront),
                        onRemove: () => _removePhoto(_PhotoSlot.aadhaarFront),
                        onPreview: () => openImageViewer(
                            context, _aadhaarFrontPhoto, 'Aadhaar Front'),
                      ),
                      _PhotoUploadCard(
                        label: 'Aadhaar Back',
                        icon: Icons.badge_outlined,
                        data: _aadhaarBackPhoto,
                        onPick: () => _pickPhotoFor(_PhotoSlot.aadhaarBack),
                        onRemove: () => _removePhoto(_PhotoSlot.aadhaarBack),
                        onPreview: () => openImageViewer(
                            context, _aadhaarBackPhoto, 'Aadhaar Back'),
                      ),
                      _PhotoUploadCard(
                        label: 'PAN Card',
                        icon: Icons.credit_card_outlined,
                        data: _panPhoto,
                        onPick: () => _pickPhotoFor(_PhotoSlot.pan),
                        onRemove: () => _removePhoto(_PhotoSlot.pan),
                        onPreview: () =>
                            openImageViewer(context, _panPhoto, 'PAN Card'),
                      ),
                      _PhotoUploadCard(
                        label: 'Signature',
                        icon: Icons.draw_outlined,
                        data: _signaturePhoto,
                        onPick: () => _pickPhotoFor(_PhotoSlot.signature),
                        onRemove: () => _removePhoto(_PhotoSlot.signature),
                        onPreview: () => openImageViewer(
                            context, _signaturePhoto, 'Signature'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                isNarrow
                    ? Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.kGoldDark,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: _handleSave,
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: Text(
                                  isEditing ? 'Save Changes' : 'Add Customer',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Cancel',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.kGoldDark,
                                foregroundColor: Colors.white,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14)),
                              ),
                              onPressed: _handleSave,
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: Text(
                                  isEditing ? 'Save Changes' : 'Add Customer',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                          ),
                        ],
                      ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sectionLabel(IconData icon, String label) {
    return Row(
      children: [
        Icon(icon, size: 15, color: AppColors.kGoldDark),
        const SizedBox(width: 8),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: AppColors.kGoldDark,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: AppColors.kBorder, height: 1)),
      ],
    );
  }

  Widget _buildInputField(
    String label,
    String hint,
    TextEditingController controller, {
    int maxLines = 1,
    bool obscureText = false,
    String? Function(String?)? validator,
    IconData? prefixIcon,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.kTextMuted)),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            maxLines: obscureText ? 1 : maxLines,
            obscureText: obscureText,
            validator: validator,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            textCapitalization: textCapitalization,
            style: const TextStyle(color: AppColors.kTextDark, fontSize: 14),
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: prefixIcon != null
                  ? Icon(prefixIcon, size: 18, color: AppColors.kTextMuted)
                  : null,
              suffixIcon: suffixIcon,
              filled: true,
              fillColor: AppColors.kSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.kBorder),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.kBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.kGoldDark, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: AppColors.kDanger),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    const BorderSide(color: AppColors.kDanger, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            ),
          ),
        ],
      ),
    );
  }
}

enum _PhotoSlot { profile, aadhaarFront, aadhaarBack, pan, signature }

// ---------------------------------------------------------
// Reusable upload card used in the form for each of the 4
// photo/document slots. Tap the image to preview full-screen,
// tap the camera badge to pick/replace, tap "Remove" to clear.
// ---------------------------------------------------------

class _PhotoUploadCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? data;
  final VoidCallback onPick;
  final VoidCallback onRemove;
  final VoidCallback onPreview;

  const _PhotoUploadCard({
    required this.label,
    required this.icon,
    required this.data,
    required this.onPick,
    required this.onRemove,
    required this.onPreview,
  });

  bool get _hasImage => data != null && data!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.kBackground,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.kBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _hasImage ? onPreview : onPick,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(14)),
                      child: _hasImage
                          ? DocumentImage(data: data, fit: BoxFit.cover)
                          : Container(
                              color: AppColors.kBorder.withOpacity(0.25),
                              child: Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(icon,
                                        size: 24,
                                        color: AppColors.kTextMuted),
                                    const SizedBox(height: 4),
                                    const Text(
                                      'Tap to upload',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: AppColors.kTextMuted),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: GestureDetector(
                    onTap: onPick,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.kGoldDark,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                      child: const Icon(Icons.camera_alt_outlined,
                          size: 14, color: Colors.white),
                    ),
                  ),
                ),
                if (_hasImage)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.zoom_in,
                          size: 12, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              children: [
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.kTextDark),
                ),
                if (_hasImage)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: GestureDetector(
                      onTap: onRemove,
                      child: const Text(
                        'Remove',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: AppColors.kDanger),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}